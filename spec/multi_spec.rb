# frozen_string_literal: true

require 'async'
require 'timeout'

describe "Patron::Multi", :session do
  let(:base_url) { "http://localhost:#{HTTP_PORT}" }
  let(:session) { Patron::Session.new(base_url: base_url, timeout: 20) }

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  describe "verbs" do
    it "has the Session's verbs and returns a Transfer from each of them" do
      multi = session.multi
      transfers = [
        multi.get("/test"), multi.head("/test"), multi.delete("/test"),
        multi.put("/testpost", "put body"), multi.patch("/testpatch", "patch body"),
        multi.post("/testpost", "post body"), multi.post("/testpost", a: 1, b: "two"),
        multi.copy("/test", "/elsewhere"), multi.request(:get, "/test", {}, query: { q: 1 })
      ]
      expect(transfers).to all(be_a(Patron::Transfer))
      expect(transfers.map(&:done?)).to all(be(false))
      expect(multi.join_all).to equal(multi)
      expect(transfers.map(&:succeeded?)).to all(be(true))

      expect(readback(transfers[0].response.body).request_method).to eq("GET")
      expect(transfers[1].response.status).to eq(200)
      expect(readback(transfers[2].response.body).request_method).to eq("DELETE")
      expect(readback(transfers[3].response.body).body).to eq("put body")
      expect(readback(transfers[4].response.body).body).to eq("patch body")
      expect(readback(transfers[5].response.body).body).to eq("post body")
      expect(readback(transfers[6].response.body).body).to eq("a=1&b=two")
      expect(readback(transfers[6].response.body).content_type).to eq("application/x-www-form-urlencoded")
      expect(readback(transfers[7].response.body).request_method).to eq("COPY")
      expect(readback(transfers[8].response.body).query_string).to eq("q=1")
    end

    it "uses the Session's defaults, base URL and headers" do
      session.headers["X-Pack"] = "yes"
      transfer = session.multi.get("/test")
      transfer.join
      request = readback(transfer.response.body)
      expect(request.path).to eq("/test")
      expect(request.header["x-pack"]).to eq(["yes"])
      expect(transfer.request.url).to eq("#{base_url}/test")
    end

    it "takes a prebuilt Request through add and <<" do
      multi = session.multi
      a = multi.add(session.build_request(:get, "/test"))
      b = multi << session.build_request(:head, "/test")
      multi.join_all
      expect(a.response.status).to eq(200)
      expect(b.response.status).to eq(200)
      expect(multi.transfers).to eq([a, b])
    end

    it "lets a finished transfer's Request be sent again" do
      first = session.multi.get("/test").join
      again = session.multi.add(first.request).join
      expect(readback(again.response.body).path).to eq("/test")
    end
  end

  describe "parallelism" do
    it "runs the requests of a pack at the same time", :timing do
      multi = session.multi
      started = monotonic
      transfers = 3.times.map { multi.get("/timeout?millis=800") }
      multi.join_all
      elapsed = monotonic - started
      expect(transfers.map { |t| t.response.status }).to eq([200, 200, 200])
      expect(elapsed).to be < 2.0 # 2.4 s if serial
    end

    it "sends a request on the verb call when a connection is warm, before anybody joins", :timing do
      session.get("/test") # warms the connection; on a cold one the verb call only starts connecting
      multi = session.multi
      transfer = multi.get("/timeout?millis=600")
      sleep 0.7
      started = monotonic
      transfer.join
      expect(monotonic - started).to be < 0.3
      expect(transfer.response.status).to eq(200)
    end

    it "caps the connections of a pack with max_connections", :timing do
      multi = session.multi(max_connections: 1)
      started = monotonic
      transfers = 2.times.map { multi.get("/timeout?millis=400") }
      multi.join_all
      expect(transfers.map { |t| t.response.status }).to eq([200, 200])
      expect(monotonic - started).to be >= 0.75 # one connection, so one after the other
    end
  end

  describe "Transfer" do
    it "reports its state and raises InFlight for a response before the join" do
      transfer = session.multi.get("/timeout?millis=300")
      expect(transfer.done?).to be(false)
      expect(transfer.succeeded?).to be(false)
      expect(transfer.failed?).to be(false)
      expect(transfer.streaming?).to be(false)
      expect(transfer.inspect).to include("GET", "/timeout", "in_flight")
      expect { transfer.response }.to raise_error(Patron::InFlight, /join/)
      expect(Patron::InFlight.ancestors).not_to include(Patron::Error)
      transfer.join
      expect(transfer.done?).to be(true)
      expect(transfer.succeeded?).to be(true)
      expect(transfer.response).to be_a(Patron::Response)
      expect(transfer.error).to be_nil
    end

    it "joins like a Thread: self when done, nil on a limit, the error re-raised" do
      multi = session.multi
      slow = multi.get("/timeout?millis=900")
      expect(slow.join(0.2)).to be_nil
      expect(slow.done?).to be(false)
      expect(slow.join).to equal(slow)

      failing = multi.request(:get, "/timeout?millis=1500", {}, timeout: 0.3)
      expect { failing.join }.to raise_error(Patron::TimeoutError)
      expect(failing.failed?).to be(true)
      expect(failing.error).to be_a(Patron::TimeoutError)
      expect { failing.join }.to raise_error(Patron::TimeoutError) # every join re-raises, like Thread#join
      expect { failing.response }.to raise_error(Patron::TimeoutError)
    end

    it "keeps a failure to itself: the pack and the other transfers are fine" do
      multi = session.multi
      failing = multi.request(:get, "/timeout?millis=1500", {}, timeout: 0.3)
      fine = multi.get("/test")
      expect(multi.join_all).to equal(multi)
      expect(failing.failed?).to be(true)
      expect(fine.response.status).to eq(200)
      expect(multi.select(&:failed?)).to eq([failing])
    end

    it "fails with the request's own error class" do
      multi = session.multi
      unresolvable = multi.get("http://nonexistent.invalid./")
      bad_port = multi.request(:get, "http://127.0.0.1:1/", {}, connect_timeout: 2)
      multi.join_all
      expect(unresolvable.error).to be_a(Patron::HostResolutionError)
      expect(bad_port.error).to be_a(Patron::ConnectionFailed)
    end

    it "can be interrupted alone" do
      multi = session.multi
      doomed = multi.get("/timeout?millis=3000")
      fine = multi.get("/test")
      started = monotonic
      doomed.interrupt
      multi.join_all
      expect(monotonic - started).to be < 1.5
      expect(doomed.error).to be_a(Patron::Aborted)
      expect(fine.response.status).to eq(200)
      expect(doomed.interrupt).to equal(doomed) # a no-op once done
    end

    it "honours per-request options" do
      multi = session.multi
      limited = multi.request(:get, "/very-large", {}, download_byte_limit: 1000)
      progressed = []
      watched = multi.request(:get, "/test", {}, progress_callback: ->(*a) { progressed << a })
      multi.join_all
      expect(limited.error).to be_a(Patron::DownloadLimitExceeded)
      expect(watched.response.status).to eq(200)
      expect(progressed).not_to be_empty
    end

    it "lets a progress callback that raises come out of the join and marks the transfer failed" do
      multi = session.multi
      raising = multi.request(:get, "/test", {}, progress_callback: ->(*) { raise "boom from progress" })
      fine = multi.get("/test")
      expect { multi.join_all }.to raise_error(RuntimeError, "boom from progress")
      expect(raising.failed?).to be(true)
      expect(raising.error.message).to eq("boom from progress")
      multi.join_all
      expect(fine.response.status).to eq(200)
    end
  end

  describe "the pack" do
    it "is Enumerable in completion order and each drives it" do
      multi = session.multi
      slow = multi.get("/timeout?millis=700")
      fast = multi.get("/test")
      failing = multi.request(:get, "/timeout?millis=2000", {}, timeout: 0.3)
      order = multi.map { |t| t }
      expect(order).to eq([fast, failing, slow])
      expect(multi.each).to be_a(Enumerator)
      expect(multi.count(&:succeeded?)).to eq(2)
      expect(multi.transfers).to eq([slow, fast, failing])
    end

    it "join_all takes a limit and returns nil when it passes" do
      multi = session.multi
      multi.get("/timeout?millis=800")
      expect(multi.join_all(0.2)).to be_nil
      expect(multi.done?).to be(false)
      expect(multi.join_all).to equal(multi)
      expect(multi.done?).to be(true)
    end

    it "keeps the Session busy while transfers are in flight and frees it when they are done" do
      multi = session.multi
      multi.get("/timeout?millis=400")
      expect { session.get("/test") }.to raise_error(Patron::Error, /already performing/)
      expect { session.multi.get("/test") }.to raise_error(Patron::Error, /already performing/)
      multi.join_all
      expect(session.get("/test").status).to eq(200)
      # and the same pack can go another round
      again = multi.get("/test")
      multi.join_all
      expect(again.response.status).to eq(200)
    end

    it "refuses the Session's transfers from another thread" do
      multi = session.multi
      transfer = multi.get("/timeout?millis=300")
      other_thread = Thread.new { Thread.current.report_on_exception = false; multi.join_all }
      expect { other_thread.join }.to raise_error(Patron::Error, /another thread/)
      multi.join_all
      expect(transfer.response.status).to eq(200)
    end

    it "closes with the transfers in flight aborted, then refuses more requests" do
      multi = session.multi
      doomed = multi.get("/timeout?millis=3000")
      multi.close
      expect(multi.closed?).to be(true)
      expect(doomed.failed?).to be(true)
      expect(doomed.error).to be_a(Patron::Aborted)
      expect { multi.get("/test") }.to raise_error(Patron::Error, /closed/)
      expect(session.get("/test").status).to eq(200)
      expect(multi.close).to equal(multi)
    end

    it "yields the pack in the block form, joins it all and closes it" do
      pack = session.multi do |m|
        m.get("/test")
        m.get("/timeout?millis=200")
      end
      expect(pack).to be_a(Patron::Multi)
      expect(pack.closed?).to be(true)
      expect(pack.transfers.map { |t| t.response.status }).to eq([200, 200])
      expect(session.get("/test").status).to eq(200)
    end

    it "closes in the block form when the block raises" do
      expect {
        session.multi do |m|
          m.get("/timeout?millis=3000")
          raise "leaving"
        end
      }.to raise_error(RuntimeError, "leaving")
      expect(session.get("/test").status).to eq(200)
    end

    it "interrupts every transfer with Session#interrupt from another thread" do
      multi = session.multi
      transfers = 2.times.map { multi.get("/timeout?millis=5000") }
      Thread.new { sleep 0.3; session.interrupt }
      multi.join_all
      expect(transfers.map { |t| t.error }).to all(be_a(Patron::Aborted))
    end

    it "is interrupted by Timeout.timeout around a join and leaves the Session usable" do
      multi = session.multi
      multi.get("/timeout?millis=5000")
      expect { Timeout.timeout(0.5) { multi.join_all } }.to raise_error(Timeout::Error)
      multi.close
      expect(session.get("/test").status).to eq(200)
    end

    it "reuses the connection between the transfers of a pack and across packs" do
      log = StringIO.new
      session.enable_debug(log)
      session.multi { |m| m.get("/test") }
      session.multi { |m| m.get("/test"); m.join_all; m.get("/test") }
      expect(log.string.scan(/Re-?using existing/).size).to be >= 2
    end
  end

  describe "streams" do
    it "runs the block as the bytes arrive and has stats when it has returned", :timing do
      multi = session.multi
      got = []
      head_at = nil
      started = monotonic
      transfer = multi.get_stream("/slow-chunks?count=5&size=8&delay=0.2") do |stream|
        head_at = monotonic - started
        expect(stream).to be_a(Patron::ResponseStream)
        expect(stream.status).to eq(200)
        stream.each { |chunk| got << [chunk, monotonic - started] }
      end
      expect(transfer.streaming?).to be(true)
      expect { transfer.stats }.to raise_error(Patron::InFlight)
      expect { transfer.response }.to raise_error(ArgumentError, /stats/)
      expect(transfer.join).to equal(transfer)
      expect(got.map(&:first).join).to eq(%w[a b c d e].map { |c| c * 8 }.join)
      expect(head_at).to be < 0.5
      expect(got.last.last - got.first.last).to be > 0.5 # the lines came over time, not in one go
      expect(transfer.stats).to be_a(Patron::TransferStats)
      expect(transfer.stats.complete?).to be(true)
      expect(transfer.stats.downloaded_bytes).to eq(40)
      expect(transfer.stats.status).to eq(200)
    end

    it "consumes several streams interleaved, alongside buffered requests", :timing do
      multi = session.multi
      events = []
      alice = multi.get_stream("/slow-chunks?count=4&size=8&delay=0.15") { |s| s.each { |c| events << [:alice, c[0]] } }
      bob = multi.get_stream("/slow-chunks?count=4&size=8&delay=0.15") { |s| s.each { |c| events << [:bob, c[0]] } }
      meta = multi.get("/test")
      started = monotonic
      multi.join_all
      expect(monotonic - started).to be < 1.5 # 0.6 s each, serially 1.2
      expect(meta.response.status).to eq(200)
      expect(alice.stats.downloaded_bytes).to eq(32)
      expect(bob.stats.downloaded_bytes).to eq(32)
      names = events.map(&:first)
      # neither stream ran to completion before the other got a turn
      expect(names.index(:bob)).to be < names.rindex(:alice)
      expect(names.index(:alice)).to be < names.rindex(:bob)
      expect(events.select { |n, _| n == :alice }.map(&:last).join).to eq("abcd")
    end

    it "takes the stream verbs with bodies and a POST Hash" do
      multi = session.multi
      seen = {}
      put = multi.put_stream("/testpost", "put body") { |s| seen[:put] = readback(s.read) }
      post = multi.post_stream("/testpost", { a: 1 }) { |s| seen[:post] = readback(s.read) }
      patch = multi.patch_stream("/testpatch", "patch body") { |s| seen[:patch] = readback(s.read) }
      multi.join_all
      expect([put, post, patch].map(&:succeeded?)).to all(be(true))
      expect(seen[:put].body).to eq("put body")
      expect(seen[:post].body).to eq("a=1")
      expect(seen[:patch].body).to eq("patch body")
    end

    it "requires a block" do
      expect { session.multi.get_stream("/test") }.to raise_error(ArgumentError, /block/)
      expect { session.multi.stream(:get, "/test") }.to raise_error(ArgumentError, /block/)
    end

    it "copies to a file with IO.copy_stream, which is what get_file does" do
      Tempfile.create("pack") do |file|
        transfer = session.multi.get_stream("/picture") { |s| IO.copy_stream(s, file) }
        transfer.join
        file.rewind
        expect(file.read).to eq(File.binread(File.join(__dir__, "support", "pic.png")))
        expect(transfer.stats.downloaded_bytes).to eq(file.size)
      end
    end

    it "fails a transfer whose block raises, and the exception comes out of the join" do
      multi = session.multi
      raising = multi.get_stream("/test") { |s| raise ArgumentError, "no thanks" }
      fine = multi.get("/test")
      expect { multi.join_all }.to raise_error(ArgumentError, "no thanks")
      expect(raising.failed?).to be(true)
      expect(raising.error).to be_a(ArgumentError)
      expect { raising.join }.to raise_error(ArgumentError, "no thanks")
      multi.join_all
      expect(fine.response.status).to eq(200)
    end

    it "fails a stream that times out mid-body with the error raised inside the block" do
      multi = session.multi
      inside = nil
      stalled = multi.get_stream("/slow-chunks?count=100&size=8&delay=0.5", {}, read_timeout: 0.2) do |s|
        begin
          s.read
        rescue Patron::TimeoutError => e
          inside = e
          raise
        end
      end
      expect { stalled.join }.to raise_error(Patron::TimeoutError, /Read timeout/)
      expect(inside).to be_a(Patron::TimeoutError)
      expect(stalled.failed?).to be(true)
    end

    it "fails a stream that cannot connect before the block runs" do
      multi = session.multi
      ran = false
      transfer = multi.request(:get, "http://127.0.0.1:1/", {}, connect_timeout: 2) { |s| ran = true }
      multi.join_all
      expect(ran).to be(false)
      expect(transfer.error).to be_a(Patron::ConnectionFailed)
    end

    it "closes a stream whose block returns early and keeps going" do
      multi = session.multi
      short = multi.get_stream("/slow-chunks?count=50&size=8&delay=0.05") { |s| s.readpartial(8) }
      multi.join_all
      expect(short.succeeded?).to be(true)
      expect(short.stats.complete?).to be(false)
      expect(session.get("/test").status).to eq(200)
    end

    it "unwinds the blocks when the pack is closed under them" do
      multi = session.multi
      ensured = false
      transfer = multi.get_stream("/slow-chunks?count=100&size=8&delay=0.5") do |s|
        begin
          s.read
        ensure
          ensured = true
        end
      end
      multi.join_all(0.3)
      multi.close
      expect(ensured).to be(true)
      expect(transfer.failed?).to be(true)
      expect(transfer.error).to be_a(Patron::Aborted)
      expect(session.get("/test").status).to eq(200)
    end

    it "refuses to join from inside a block" do
      multi = session.multi
      other = multi.get("/timeout?millis=800")
      transfer = multi.get_stream("/test") { |s| other.join }
      multi.join_all # a Patron::Error out of the block is the transfer's failure, not the join's
      expect(transfer.failed?).to be(true)
      expect(transfer.error).to be_a(Patron::Error)
      expect(transfer.error.message).to match(/inside one of its stream blocks/)
      expect { transfer.join }.to raise_error(Patron::Error, /inside one of its stream blocks/)
      expect(other.response.status).to eq(200)
    end

    it "lets a block do blocking IO of its own" do
      reader, writer = IO.pipe
      multi = session.multi
      transfer = multi.get_stream("/test") { |s| writer.write(s.read); writer.close }
      multi.join_all
      expect(readback(reader.read).path).to eq("/test")
      expect(transfer.succeeded?).to be(true)
    end
  end

  describe "under a Fiber scheduler", :fibers do
    it "drives a pack inside Async and lets other tasks run meanwhile", :timing do
      ticks = 0
      Async do |task|
        ticker = task.async { 30.times { ticks += 1; sleep 0.02 } }
        multi = session.multi
        transfers = 2.times.map { multi.get("/timeout?millis=500") }
        multi.join_all
        expect(transfers.map { |t| t.response.status }).to eq([200, 200])
        expect(ticks).to be >= 10
        ticker.wait
      end
    end

    it "streams inside Async, with a block that does IO of its own" do
      Async do
        reader, writer = IO.pipe
        multi = session.multi
        lines = []
        transfer = multi.get_stream("/counter?lines=3&delay=0.1") { |s| s.each_line { |l| writer.write(l); lines << l } }
        multi.join_all
        writer.close
        expect(reader.read).to eq(lines.join)
        expect(transfer.stats.complete?).to be(true)
      end
    end

    it "is interrupted by Task#with_timeout and leaves the Session usable" do
      Async do |task|
        multi = session.multi
        multi.get("/timeout?millis=5000")
        expect { task.with_timeout(0.5) { multi.join_all } }.to raise_error(Async::TimeoutError)
        multi.close
        expect(session.get("/test").status).to eq(200)
      end
    end

    it "is interrupted at once by Multi#interrupt from another fiber", :timing do
      Async do |task|
        multi = session.multi
        transfer = multi.get("/timeout?millis=5000")
        task.async { sleep 0.2; multi.interrupt }
        started = monotonic
        expect { multi.join_all }.to raise_error(Patron::Aborted)
        expect(monotonic - started).to be < 1.0
        multi.close
        expect(transfer.done?).to be(true)
      end
    end
  end
end
