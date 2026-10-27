# frozen_string_literal: true

require 'async'

# A Session inside a Fiber scheduler (here: async) yields to it while libcurl waits for the
# network, so other fibers on the same thread keep running
describe "Patron::Session under a Fiber scheduler", :session do
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
end
