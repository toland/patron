# frozen_string_literal: true

require 'socket'
require 'stringio'
require 'tempfile'
require 'timeout'

describe "Patron::Session#stream", :session do
  let(:base_url) { "http://localhost:#{HTTP_PORT}" }
  let(:session) { Patron::Session.new(base_url: base_url, timeout: 20) }

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # libcurl 8 says "Reusing existing http: connection with host", libcurl 7 "Re-using existing connection"
  REUSED_CONNECTION = /Re-?using existing/

  def counter_body(lines) = (0...lines).map { |i| format("%07d\n", i) }.join

  # A one-shot HTTP server writing `response` verbatim, for what Puma cannot send
  def with_raw_response(response)
    server = TCPServer.new('127.0.0.1', 0)
    thread = Thread.new do
      conn = server.accept
      nil while (line = conn.gets) && line != "\r\n"
      conn.write(response)
      sleep 0.2
      conn.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    thread&.join(5)
    server&.close
  end

  it "raises ArgumentError without a block" do
    expect { session.stream(:get, "/test") }.to raise_error(ArgumentError, /block/)
    expect { session.get_stream("/test") }.to raise_error(ArgumentError, /block/)
    expect(session.get("/test").status).to eq(200)
  end

  it "yields the head before the first body byte has arrived", :timing do
    started = monotonic
    head_at = nil
    stats = session.get_stream("/long-poll?delay=1") do |stream|
      head_at = monotonic - started
      expect(stream.status).to eq(200)
      expect(stream.status_line).to eq("HTTP/1.1 200 OK")
      expect(stream.ok?).to be(true)
      expect(stream.error?).to be(false)
      expect(stream.headers["x-long-poll"]).to eq("yes")
      expect(stream.content_type).to eq("text/event-stream")
      expect(stream.charset).to eq("utf-8")
      expect(stream.content_length).to be_nil
      expect(stream.url).to eq("#{base_url}/long-poll?delay=1")
      expect(stream.redirect_count).to eq(0)
      expect(stream.read).to eq("first\nsecond\n")
    end
    expect(head_at).to be < 0.5 # the server holds the body back for a second
    expect(stats).to be_a(Patron::TransferStats)
    expect(stats.status).to eq(200)
    expect(stats.content_type).to eq("text/event-stream")
    expect(stats.complete?).to be(true)
    expect(stats.downloaded_bytes).to eq(13)
  end

  it "has content_length on both the stream and the receipt" do
    stats = session.get_stream("/counter?lines=10") do |stream|
      expect(stream.content_length).to eq(80)
      stream.drain!
    end
    expect(stats.content_length).to eq(80)
    expect(stats.downloaded_bytes).to eq(80)
  end

  it "follows redirects and reports the final response" do
    stats = session.get_stream("/redirect") do |stream|
      expect(stream.status).to eq(200)
      expect(stream.redirect_count).to eq(1)
      expect(stream.headers).not_to have_key("location")
      expect(readback(stream.read).path).to eq("/test")
    end
    expect(stats.redirect_count).to eq(1)
    expect(stats.url).to eq("http://localhost:#{HTTP_PORT}/test")
  end

  it "yields binary chunks from #each that add up to the body" do
    chunks = []
    session.get_stream("/counter?lines=50000&per_chunk=3000") { |stream| stream.each { |c| chunks << c } }
    expect(chunks.length).to be > 1
    expect(chunks.map(&:encoding).uniq).to eq([Encoding::BINARY])
    expect(chunks.map(&:object_id).uniq.length).to eq(chunks.length)
    expect(chunks.join).to eq(counter_body(50000))
  end

  it "returns an Enumerator from #each and #each_line without a block" do
    session.get_stream("/slow-chunks?count=3&size=4&delay=0") do |stream|
      expect(stream.each).to be_a(Enumerator)
      expect(stream.each_line).to be_a(Enumerator)
      expect(stream.each.to_a.join).to eq("aaaabbbbcccc")
    end
  end

  it "splits lines with #each_line, the last one without its newline" do
    body = "one\ntwo\n\nthree"
    with_raw_response("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}") do |url|
      lines = []
      session.get_stream("#{url}/") { |stream| stream.each_line { |l| lines << l } }
      expect(lines).to eq(["one\n", "two\n", "\n", "three"])
    end
  end

  it "splits lines that span chunks" do
    lines = []
    session.get_stream("/counter?lines=3000&per_chunk=7") { |stream| stream.each_line { |l| lines << l } }
    expect(lines.length).to eq(3000)
    expect(lines.join).to eq(counter_body(3000))
  end

  it "fills the caller's String in place with read and readpartial" do
    buf = String.new
    session.get_stream("/counter?lines=1000") do |stream|
      expect(stream.read(100, buf)).to equal(buf)
      expect(buf.bytesize).to eq(100)
      expect(buf.encoding).to eq(Encoding::BINARY)
      expect(stream.readpartial(100, buf)).to equal(buf)
      expect(buf.bytesize).to be_between(1, 100)
    end
  end

  it "follows IO#read semantics at the end of the body" do
    session.get_stream("/counter?lines=2") do |stream|
      expect(stream.read(0)).to eq("")
      expect(stream.read(5)).to eq("00000")
      expect(stream.read(100)).to eq("00\n0000001\n")
      expect(stream.read(1)).to be_nil
      expect(stream.read).to eq("")
      expect(stream.eof?).to be(true)
      expect { stream.readpartial(10) }.to raise_error(EOFError)
      expect(stream.drain!).to eq(0)
    end
  end

  it "reads ahead for #eof? without losing those bytes" do
    session.get_stream("/counter?lines=3") do |stream|
      expect(stream.read(4)).to eq("0000")
      expect(stream.eof?).to be(false)
      expect(stream.read(6)).to eq("000\n00")
      expect(stream.read).to eq("00001\n0000002\n")
      expect(stream.eof?).to be(true)
    end
  end

  it "hands out every byte exactly once and in order when reading less than libcurl delivers" do
    received = String.new
    buf = String.new
    session.get_stream("/counter?lines=100000&per_chunk=5000") do |stream|
      loop do
        stream.readpartial(333, buf)
        expect(buf.bytesize).to be <= 333
        received << buf
      rescue EOFError
        break
      end
    end
    expect(received).to eq(counter_body(100000))
  end

  it "does not allocate per chunk when reading into the caller's String" do
    buf = String.new(capacity: 16384)
    sink = Object.new
    def sink.write(str) = str.bytesize
    allocated = nil
    total = 0
    session.get_stream("/very-large") do |stream|
      stream.read(16384, buf)
      before = GC.stat(:total_allocated_objects)
      while stream.read(16384, buf)
        total += sink.write(buf)
      end
      allocated = GC.stat(:total_allocated_objects) - before
    end
    expect(total).to eq(15 * 1024 * 1024 - 16384)
    expect(allocated).to be < 50 # some 960 reads of 16 KB
  end

  it "does not allocate per chunk with readpartial either" do
    buf = String.new(capacity: 16384)
    allocated = nil
    session.get_stream("/very-large") do |stream|
      stream.readpartial(16384, buf)
      before = GC.stat(:total_allocated_objects)
      begin
        loop { stream.readpartial(16384, buf) }
      rescue EOFError
        nil
      end
      allocated = GC.stat(:total_allocated_objects) - before
    end
    expect(allocated).to be < 50
  end

  it "refuses a frozen buffer" do
    session.get_stream("/counter?lines=10") do |stream|
      expect { stream.read(10, "frozen".freeze) }.to raise_error(FrozenError)
    end
  end

  it "copies into a Tempfile with IO.copy_stream" do
    tf = Tempfile.new("patron-stream")
    tf.binmode
    stats = session.get_stream("/counter?lines=20000") { |stream| IO.copy_stream(stream, tf) }
    tf.flush
    expect(File.binread(tf.path)).to eq(counter_body(20000))
    expect(stats.downloaded_bytes).to eq(160000)
  end

  it "copies into an object that only has #write with IO.copy_stream" do
    sink = Class.new do
      attr_reader :data
      def initialize = @data = String.new
      def write(str) = (@data << str; str.bytesize)
    end.new
    session.get_stream("/counter?lines=20000") { |stream| IO.copy_stream(stream, sink) }
    expect(sink.data).to eq(counter_body(20000))
  end

  it "drains the rest of the body, keeps the connection and says the transfer completed" do
    log = StringIO.new
    session.enable_debug(log)
    stats = session.get_stream("/error-with-body") do |stream|
      expect(stream.status).to eq(503)
      expect(stream.error?).to be(true)
      expect(stream.read(96).bytesize).to eq(96)
      expect(stream.drain!).to eq(4000)
      expect(stream.drain!).to eq(0)
    end
    expect(stats.complete?).to be(true)
    expect(stats.downloaded_bytes).to eq(4096)
    log.truncate(0)
    log.rewind
    expect(session.get("/test").status).to eq(200)
    expect(log.string).to match(REUSED_CONNECTION)
  end

  it "closes the connection and reports an incomplete transfer after break" do
    log = StringIO.new
    session.enable_debug(log)
    chunks = 0
    stats = session.get_stream("/counter?lines=100000&per_chunk=100") do |stream|
      stream.each { chunks += 1; break if chunks == 2 }
    end
    expect(stats.complete?).to be(false)
    expect(session.get_stream("/counter?lines=100000") { break :broke }).to eq(:broke)

    stats = session.get_stream("/counter?lines=100000&per_chunk=100") { |stream| stream.read(10); stream.close }
    expect(stats.complete?).to be(false)
    expect(stats.trailers).to eq({})
    log.truncate(0)
    log.rewind
    expect(session.get("/test").status).to eq(200)
    expect(log.string).not_to match(REUSED_CONNECTION)
  end

  it "can be left by raising, and the Session stays usable" do
    expect {
      session.get_stream("/counter?lines=100000") { |stream| stream.read(10); raise ArgumentError, "bail" }
    }.to raise_error(ArgumentError, "bail")
    expect(session.get("/test").status).to eq(200)
  end

  it "can be left by returning from the enclosing method, and the Session stays usable" do
    def first_bytes(session)
      session.get_stream("/counter?lines=100000") { |stream| return stream.read(7) }
    end
    expect(first_bytes(session)).to eq("0000000")
    expect(first_bytes(session)).to eq("0000000")
    expect(session.get("/test").status).to eq(200)
  end

  it "bails out on the head without reading the body" do
    expect {
      session.get_stream("/very-large") do |stream|
        raise RangeError, stream.content_length.to_s if stream.content_length > 1024
      end
    }.to raise_error(RangeError, (15 * 1024 * 1024).to_s)
    expect(session.get("/test").status).to eq(200)
  end

  it "raises IOError when the stream is used after its block" do
    leaked = nil
    session.get_stream("/counter?lines=10") { |stream| leaked = stream }
    expect(leaked).to be_closed
    expect { leaked.read }.to raise_error(IOError, "closed stream")
    expect { leaked.read(1, String.new) }.to raise_error(IOError, "closed stream")
    expect { leaked.readpartial(1) }.to raise_error(IOError, "closed stream")
    expect { leaked.each { } }.to raise_error(IOError, "closed stream")
    expect { leaked.each_line { } }.to raise_error(IOError, "closed stream")
    expect { leaked.drain! }.to raise_error(IOError, "closed stream")
    expect { leaked.eof? }.to raise_error(IOError, "closed stream")
    expect { leaked.close }.not_to raise_error
    expect(leaked.status).to eq(200) # the head stays readable
  end

  it "refuses a second request on the Session from inside the block" do
    session.get_stream("/counter?lines=10") do |stream|
      expect { session.get("/test") }.to raise_error(Patron::Error, /another thread or fiber/)
      expect { session.get_stream("/test") { } }.to raise_error(Patron::Error, /another thread or fiber/)
      expect(stream.read).to eq(counter_body(10))
    end
    expect(session.get("/test").status).to eq(200)
  end

  it "keeps the transfer primitives defensive" do
    expect { session.send(:transfer_read, 10, String.new) }.to raise_error(Patron::Error, /No streamed transfer/)
    expect(session.send(:transfer_finish)).to be_nil
  end

  it "raises the usual errors when the transfer fails before a head" do
    expect {
      session.get_stream("http://127.0.0.1:1/") { raise "not reached" }
    }.to raise_error(Patron::ConnectionFailed)
    expect(session.get("/test").status).to eq(200)
  end

  it "streams a POST with a form-encoded Hash, a PUT and a PATCH" do
    session.post_stream("/test", { "a" => "b c" }) do |stream|
      echo = readback(stream.read)
      expect(echo.request_method).to eq("POST")
      expect(echo.body).to eq("a=b%20c") # the same encoding as #post
      expect(echo.header["content-type"]).to eq(["application/x-www-form-urlencoded"])
    end
    session.put_stream("/test", StringIO.new("put body")) { |s| expect(readback(s.read).body).to eq("put body") }
    session.patch_stream("/test", "patch body") { |s| expect(readback(s.read).request_method).to eq("PATCH") }
    stats = session.stream(:delete, "/test") { |s| expect(readback(s.read).request_method).to eq("DELETE") }
    expect(stats.uploaded_bytes).to eq(0)
  end

  it "has no body to stream for a HEAD" do
    stats = session.stream(:head, "/test") do |stream|
      expect(stream.status).to eq(200)
      expect(stream.read).to eq("")
      expect(stream.read(1)).to be_nil
    end
    expect(stats.complete?).to be(true)
  end

  it "raises from #stream when a body that cannot be rewound has to be sent again after a 307" do
    reader, writer = IO.pipe
    writer.write("sent once")
    writer.close
    expect {
      session.stream(:put, "/redirect-307", {}, data: reader) { raise "not reached" }
    }.to raise_error(Patron::Error) { |e| expect(e.curl_code).to eq(65) }
    expect(session.get("/test").status).to eq(200)
  ensure
    reader&.close
  end

  it "is aborted by Session#interrupt from another thread" do
    interrupter = nil
    expect {
      session.get_stream("/slow-chunks?count=20&delay=0.25") do |stream|
        interrupter = Thread.new { sleep 0.3; session.interrupt }
        stream.each { }
      end
    }.to raise_error(Patron::Aborted)
    interrupter.join
    expect(session.get("/test").status).to eq(200)
  end

  it "is interrupted by Timeout.timeout while waiting for a chunk", :timing do
    expect {
      Timeout.timeout(0.5) { session.get_stream("/long-poll?delay=5") { |stream| stream.read } }
    }.to raise_error(Timeout::Error)
    expect(session.get("/test").status).to eq(200)
  end

  it "applies download_byte_limit" do
    session.download_byte_limit = 1024
    expect {
      session.get_stream("/very-large") { |stream| stream.drain! }
    }.to raise_error(Patron::DownloadLimitExceeded)
    session.download_byte_limit = nil
    expect(session.get("/test").status).to eq(200)
  end

  it "runs the progress callback" do
    calls = 0
    session.progress_callback = proc { calls += 1 }
    session.get_stream("/slow-chunks?count=3&delay=0.05") { |stream| stream.drain! }
    expect(calls).to be > 0
  end

  it "propagates an exception from the progress callback out of a read" do
    session.progress_callback = proc { |_, dlnow| raise ArgumentError, "from progress" if dlnow > 0 }
    expect {
      session.get_stream("/counter?lines=100000") { |stream| stream.drain! }
    }.to raise_error(ArgumentError, "from progress")
    session.progress_callback = nil
    expect(session.get("/test").status).to eq(200)
  end

  context "with read_timeout" do
    it "raises a TimeoutError on a stream that stalls, and the Session stays usable", :timing do
      started = monotonic
      expect {
        session.get_stream("/long-poll?delay=3", {}, read_timeout: 0.3) { |stream| stream.read }
      }.to raise_error(Patron::TimeoutError, /read timeout/i) { |e| expect(e.curl_code).to eq(28) }
      expect(monotonic - started).to be < 1.5
      expect(session.get("/test").status).to eq(200)
    end

    it "lets a stream through whose chunks come quicker than the read timeout" do
      stats = session.get_stream("/slow-chunks?count=5&delay=0.1", {}, read_timeout: 0.5) { |stream| stream.drain! }
      expect(stats.complete?).to be(true)
    end

    it "applies to buffered requests too", :timing do
      session.read_timeout = 0.3
      started = monotonic
      expect { session.get("/timeout?millis=2000") }.to raise_error(Patron::TimeoutError, /read timeout/i)
      expect(monotonic - started).to be < 1.5
      expect(session.get("/slow-chunks?count=4&delay=0.1").body.bytesize).to eq(4096)
    end

    it "is validated by Request" do
      expect { session.request(:get, "/test", {}, read_timeout: 0) }.to raise_error(ArgumentError)
      expect { session.request(:get, "/test", {}, read_timeout: -1) }.to raise_error(ArgumentError)
      expect(session.request(:get, "/test", {}, read_timeout: "2.5").status).to eq(200)
    end
  end

  context "with trailers" do
    let(:chunked_with_trailers) do
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\nContent-Type: text/plain\r\n\r\n" \
        "5\r\nhello\r\n6\r\n world\r\n0\r\nX-Checksum: abc123\r\nX-Multi: 1\r\nX-Multi: 2\r\n\r\n"
    end

    it "puts them on the receipt and not on the stream" do
      with_raw_response(chunked_with_trailers) do |url|
        stats = session.get_stream("#{url}/") do |stream|
          expect(stream.headers).to include("Content-Type" => "text/plain")
          expect(stream.headers).not_to have_key("X-Checksum")
          expect(stream.read).to eq("hello world")
        end
        expect(stats.complete?).to be(true)
        expect(stats.trailers).to eq("X-Checksum" => "abc123", "X-Multi" => ["1", "2"])
        expect(stats.headers).not_to have_key("X-Checksum")
      end
    end

    it "leaves them empty when the block ends early" do
      with_raw_response(chunked_with_trailers) do |url|
        stats = session.get_stream("#{url}/") { |stream| stream.read(2) }
        expect(stats.complete?).to be(false)
        expect(stats.trailers).to eq({})
      end
    end

    it "is {} without trailers" do
      stats = session.get_stream("/slow-chunks?count=2&delay=0") { |stream| stream.drain! }
      expect(stats.trailers).to eq({})
    end
  end

  it "does not take a proxy's CONNECT response for the head" do
    with_connect_proxy do |proxy|
      tls = Patron::Session.new(base_url: "https://localhost:#{HTTPS_PORT}", timeout: 10, insecure: true, proxy: proxy)
      stats = tls.get_stream("/long-poll?delay=0.3") do |stream|
        expect(stream.status).to eq(200)
        expect(stream.headers["x-long-poll"]).to eq("yes")
        expect(stream.read).to eq("first\nsecond\n")
      end
      expect(stats.complete?).to be(true)
      expect(tls.get("/test").status).to eq(200) # the buffered path still sees through the proxy
    end
  end

  it "returns a frozen, Ractor-shareable receipt" do
    stats = session.get_stream("/test") { |stream| stream.drain! }
    expect(stats).to be_frozen
    expect(Ractor.shareable?(stats)).to be(true)
    expect(stats.timings.keys).to include(:namelookup, :connect, :starttransfer, :total)
  end

  it "survives a stream abandoned with its fiber mid-body" do
    fiber = Fiber.new do
      Patron::Session.new(base_url: base_url).get_stream("/counter?lines=100000") do |stream|
        stream.read(10)
        Fiber.yield :suspended
      end
    end
    expect(fiber.resume).to eq(:suspended)
    fiber = nil
    GC.start
    GC.start
    expect(session.get("/test").status).to eq(200)
  end

  it "keeps get_file returning a Response without a body" do
    tf = Tempfile.new("patron-get-file")
    response = session.get_file("/counter?lines=1000", tf.path)
    expect(response).to be_a(Patron::Response)
    expect(response.body).to be_nil
    expect(response.status).to eq(200)
    expect(response.timings[:total]).to be > 0
    expect(File.binread(tf.path)).to eq(counter_body(1000))
  end
end
