# frozen_string_literal: true

require 'async'

# A Session inside a Fiber scheduler (here: async) yields to it while libcurl waits for the
# network, so other fibers on the same thread keep running
describe "Patron::Session under a Fiber scheduler", :session, :fibers do
  let(:base_url) { "http://localhost:#{HTTP_PORT}" }
  let(:session) { Patron::Session.new(base_url: base_url, timeout: 10) }

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  it "performs a request with a scheduler installed" do
    Async do
      expect(Fiber.scheduler).not_to be_nil
      response = session.get("/test")
      expect(response.status).to eq(200)
      expect(readback(response.body).path).to eq("/test")
    end
  end

  it "overlaps slow requests from several fibers on one thread", :timing do
    started = monotonic
    statuses = Async do |task|
      3.times.map { task.async { Patron::Session.new(base_url: base_url, timeout: 10).get("/slow").status } }.map(&:wait)
    end.wait
    expect(statuses).to eq([200, 200, 200])
    expect(monotonic - started).to be < 9 # the server answers after 5 s; serially this takes 15
  end

  it "lets other fibers run while a request is waiting", :timing do
    ticks = 0
    Async do |task|
      ticker = task.async { 40.times { ticks += 1; sleep 0.025 } }
      session.get("/timeout?millis=600")
      expect(ticks).to be >= 10
      ticker.wait
    end
  end

  it "is interrupted by Task#with_timeout and the Session stays usable" do
    Async do |task|
      expect { task.with_timeout(0.5) { session.get("/slow") } }.to raise_error(Async::TimeoutError)
      expect(session.get("/test").status).to eq(200)
    end
  end

  it "is interrupted by Task#stop" do
    Async do |task|
      requester = task.async { session.get("/slow") }
      task.async { sleep 0.3; requester.stop }
      requester.wait
      expect(requester).to be_stopped
      expect(session.get("/test").status).to eq(200)
    end
  end

  it "refuses a second fiber on the same Session while a request is in flight" do
    Async do |task|
      first = task.async { session.get("/timeout?millis=400") }
      sleep 0.1
      expect { session.get("/test") }.to raise_error(Patron::Error, /another thread or fiber/)
      expect(first.wait.status).to eq(200)
    end
  end

  it "runs the progress callback and downloads to a file" do
    calls = 0
    session.progress_callback = proc { calls += 1 }
    tf = Tempfile.new("patron-fiber")
    Async { session.get_file("/test", tf.path) }
    expect(calls).to be > 0
    expect(readback(File.read(tf.path)).path).to eq("/test")
  end

  it "streams a request body from a pipe another fiber writes to" do
    reader, writer = IO.pipe
    body = Async do |task|
      task.async do
        %w[one two three].each { |word| writer.write(word); sleep 0.02 }
        writer.close
      end
      session.put("/test", reader).body
    end.wait
    expect(readback(body).body).to eq("onetwothree")
  end

  it "talks TLS" do
    Async do
      tls = Patron::Session.new(base_url: "https://localhost:#{HTTPS_PORT}", timeout: 10, insecure: true)
      expect(tls.get("/test").status).to eq(200)
    end
  end

  it "survives compaction between requests with the socket wrappers cached" do
    skip "no compaction" unless GC.respond_to?(:verify_compaction_references)
    Async do
      session.get("/test")
      begin
        GC.verify_compaction_references(expand_heap: true, toward: :empty)
      rescue NotImplementedError
        skip "compaction not available"
      end
      expect(session.get("/test").status).to eq(200)
    end
  end
  context "with a streamed response" do
    it "streams under the scheduler and lets other fibers run while waiting for a chunk", :timing do
      ticks = 0
      lines = []
      stats = Async do |task|
        ticker = task.async { 40.times { ticks += 1; sleep 0.025 } }
        result = session.get_stream("/long-poll?delay=0.6") { |stream| stream.each_line { |l| lines << l } }
        ticker.wait
        result
      end.wait
      expect(lines).to eq(["first\n", "second\n"])
      expect(ticks).to be >= 10
      expect(stats.complete?).to be(true)
    end

    it "fills the caller's String through IO.copy_stream under the scheduler" do
      tf = Tempfile.new("patron-fiber-stream")
      stats = Async { session.get_stream("/very-large") { |stream| IO.copy_stream(stream, tf) } }.wait
      tf.flush
      expect(File.size(tf.path)).to eq(15 * 1024 * 1024)
      expect(stats.downloaded_bytes).to eq(15 * 1024 * 1024)
    end

    it "is interrupted mid-stream by Task#with_timeout and the Session stays usable" do
      received = 0
      Async do |task|
        expect {
          task.with_timeout(0.5) do
            session.get_stream("/slow-chunks?count=20&delay=0.2") { |stream| stream.each { |c| received += c.bytesize } }
          end
        }.to raise_error(Async::TimeoutError)
        expect(received).to be > 0
        expect(session.get("/test").status).to eq(200)
      end
    end

    it "is interrupted mid-stream by Task#stop" do
      received = 0
      Async do |task|
        streamer = task.async do
          session.get_stream("/slow-chunks?count=20&delay=0.2") { |stream| stream.each { |c| received += c.bytesize } }
        end
        task.async { sleep 0.5; streamer.stop }
        streamer.wait
        expect(streamer).to be_stopped
        expect(received).to be > 0
        expect(session.get("/test").status).to eq(200)
      end
    end

    it "overlaps two streams on two Sessions", :timing do
      started = monotonic
      sizes = Async do |task|
        2.times.map do
          task.async do
            stream_session = Patron::Session.new(base_url: base_url, timeout: 10)
            total = 0
            stream_session.get_stream("/slow-chunks?count=5&delay=0.3") { |stream| stream.each { |c| total += c.bytesize } }
            total
          end
        end.map(&:wait)
      end.wait
      expect(sizes).to eq([5120, 5120])
      expect(monotonic - started).to be < 2.2 # 1.2 s each; serially that is 2.4
    end

    it "refuses another fiber on the Session while a stream is open" do
      Async do |task|
        first = task.async { session.get_stream("/long-poll?delay=0.3") { |stream| stream.read } }
        sleep 0.1
        expect { session.get("/test") }.to raise_error(Patron::Error, /another thread or fiber/)
        expect { session.get_stream("/test") { } }.to raise_error(Patron::Error, /another thread or fiber/)
        expect(first.wait).to be_complete
      end
    end
  end
end
