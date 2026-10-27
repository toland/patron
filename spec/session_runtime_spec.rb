require File.expand_path("./spec") + '/spec_helper.rb'
require 'stringio'
require 'tempfile'
require 'timeout'

# Behaviour of the libcurl multi-based transfer loop: interruption, concurrency,
# callbacks, GC and process lifecycle.
describe Patron::Session do
  before(:each) do
    @session = Patron::Session.new
    @session.base_url = "http://localhost:9001"
  end

  describe "#interrupt" do
    it "aborts a request in flight from another thread, promptly", :timing do
      @session.timeout = 10
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      interrupter = Thread.new do
        sleep 0.5
        @session.interrupt
      end
      expect { @session.get("/slow") }.to raise_error(Patron::Aborted)
      interrupter.join
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < 1.5 # the server only answers after 5 seconds

      # The Session is usable again afterwards
      expect(@session.get("/test").status).to eq(200)
    end
  end

  describe "with Timeout.timeout" do
    it "is interrupted during a slow request without waiting for the server", :timing do
      @session.timeout = 10
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect {
        Timeout.timeout(0.5) { @session.get("/slow") }
      }.to raise_error(Timeout::Error)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < 1.5
      expect(@session.get("/test").status).to eq(200)
    end
  end

  describe "when used from two threads at once" do
    it "raises for the second caller instead of corrupting the transfer" do
      @session.timeout = 10
      errors = Queue.new
      threads = 2.times.map do
        Thread.new do
          @session.get("/slow")
        rescue Patron::Error => e
          errors << e
        end
      end
      threads.each(&:join)
      expect(errors.size).to eq(1)
      expect(errors.pop.message).to match(/already performing a request/)
    end
  end

  describe "progress callback" do
    it "re-raises an exception from the callback after cleaning up, and keeps the Session usable" do
      @session.timeout = 10
      @session.progress_callback = proc { raise "boom from the callback" }
      expect { @session.get("/test") }.to raise_error(RuntimeError, "boom from the callback")
      @session.progress_callback = nil
      expect(@session.get("/test").status).to eq(200)
    end

    it "lets a throw from the callback unwind to the catch around the request" do
      @session.timeout = 10
      @session.progress_callback = proc { throw :bail, :bailed }
      expect(catch(:bail) { @session.get("/test") }).to eq(:bailed)
      @session.progress_callback = nil
      expect(@session.get("/test").status).to eq(200)
    end

    it "lets Thread#kill terminate a thread that is inside the callback", :timing do
      @session.timeout = 10
      @session.progress_callback = proc { sleep 0.05 } # the kill will land inside here
      t = Thread.new { @session.get("/slow") }
      sleep 0.5
      t.kill
      expect(t.join(2)).to eq(t) # not stuck, not a TypeError about $!
      @session.progress_callback = nil
      expect(@session.get("/test").status).to eq(200)
    end

    it "aborts the request when the callback returns false" do
      @session.timeout = 10
      @session.progress_callback = proc { false }
      expect { @session.get("/slow") }.to raise_error(Patron::Aborted)
    end

    it "receives curl_off_t sized counters as Integers" do
      args = []
      @session.progress_callback = proc { |*a| args << a }
      @session.get("/test")
      expect(args).not_to be_empty
      expect(args.flatten).to all(be_a(Integer))
    end
  end

  describe "download_byte_limit" do
    it "raises DownloadLimitExceeded, which is an Aborted" do
      @session.download_byte_limit = 1024
      @session.buffer_size = 1024
      expect { @session.get("/very-large") }.to raise_error(Patron::DownloadLimitExceeded)
      expect(Patron::DownloadLimitExceeded.ancestors).to include(Patron::Aborted)
    end
  end

  describe "errors" do
    it "carry the libcurl error code" do
      @session.base_url = "http://localhost:1" # nothing listens there
      begin
        @session.get("/test")
        raise "expected a ConnectionFailed"
      rescue Patron::ConnectionFailed => e
        expect(e.curl_code).to eq(7) # CURLE_COULDNT_CONNECT
      end
    end

    it "raise for an unsupported SSL version before touching the network" do
      @session.ssl_version = "SSLv3"
      expect { @session.get("/test") }.to raise_error(Patron::UnsupportedSSLVersion)
    end

    it "raise for an unsupported HTTP version before touching the network" do
      @session.http_version = "HTTPv9"
      expect { @session.get("/test") }.to raise_error(Patron::UnsupportedHTTPVersion)
    end
  end

  describe "request bodies" do
    it "keeps a freshly built body String alive during the transfer" do
      stringable = Class.new { def to_s = "x" * 65536 }.new
      GC.stress = true
      begin
        response = @session.post("/testpost", stringable)
      ensure
        GC.stress = false
      end
      expect(readback(response.body).body).to eq("x" * 65536)
    end

    it "sends multipart field values with NUL bytes intact" do
      captured = capture_request do |url|
        @session.base_url = url
        @session.post_multipart("/test", { field: "a\0b" }, { test_file: "LICENSE" })
      end
      expect(captured.body).to include("a\0b")
      expect(captured.body).to include('name="test_file"')
    end

    it "accepts multipart PUT" do
      response = @session.request(:put, "/test", {}, data: { a: "1" }, multipart: true)
      expect(response.status).to eq(200)
    end
  end

  describe "debug output" do
    it "writes libcurl's verbose output to the given IO" do
      io = StringIO.new
      @session.enable_debug(io)
      @session.get("/test")
      expect(io.string).to include("> GET /test HTTP/1.1")
      expect(io.string).to include("< HTTP/1.1 200")
    end

    it "writes to a file when given a path" do
      tf = Tempfile.new("patron-debug")
      @session.enable_debug(tf.path)
      @session.get("/test")
      expect(File.read(tf.path)).to include("GET /test")
    end
  end

  describe "garbage collection" do
    it "survives compaction while a progress callback is set" do
      skip "no compaction support on this platform" unless GC.respond_to?(:verify_compaction_references)
      calls = 0
      @session.progress_callback = proc { calls += 1 }
      begin
        GC.verify_compaction_references(expand_heap: true, toward: :empty)
      rescue NotImplementedError
        skip "compaction not available"
      end
      @session.get("/test")
      GC.verify_compaction_references(expand_heap: true, toward: :empty)
      @session.get("/test")
      expect(calls).to be > 0
    end

    it "reports its memory size" do
      require 'objspace'
      expect(ObjectSpace.memsize_of(@session)).to be > 100
    end
  end

  describe "in a forked child" do
    it "performs requests on fresh libcurl handles" do
      @session.get("/test") # populate the connection cache in the parent
      rd, wr = IO.pipe
      pid = Process.fork do
        rd.close
        status = @session.get("/test").status
        wr.write(status.to_s)
        wr.close
        exit!(0)
      end
      wr.close
      Process.wait(pid)
      expect(rd.read).to eq("200")
      expect(@session.get("/test").status).to eq(200)
    end
  end

  describe "with Ractors" do
    it "can escape strings and perform requests from a non-main Ractor" do
      skip "Ractors are not available" unless defined?(Ractor)
      ractor = Ractor.new do
        session = Patron::Session.new
        session.base_url = "http://localhost:9001"
        [Patron::Session.escape("a b"), session.get("/test").status]
      end
      result = ractor.respond_to?(:value) ? ractor.value : ractor.take
      expect(result).to eq(["a%20b", 200])
    end
  end

  describe "#response_class" do
    it "receives keyword arguments" do
      custom = Class.new do
        attr_reader :kwargs
        def initialize(**kwargs) = @kwargs = kwargs
      end
      session_class = Class.new(Patron::Session) { define_method(:response_class) { custom } }
      session = session_class.new(base_url: "http://localhost:9001")
      response = session.get("/test")
      expect(response.kwargs.keys).to contain_exactly(:url, :status, :redirect_count, :header_data, :body, :default_charset, :timings)
      expect(response.kwargs[:timings]).to include(:total)
    end
  end
end
