require 'socket'
require 'openssl'
require 'stringio'

# Captures the raw HTTP request a client puts on the wire, independent of any
# Rack/HTTP server. This lets us assert on hop-by-hop details such as
# Transfer-Encoding which a conformant server (webrick, puma, ...) decodes and
# never exposes to the application.
module RawRequestCapture
  CapturedRequest = Struct.new(:request_line, :headers, :body)

  CERT_DIR = File.join(__dir__, 'certs')

  # Boots a one-shot capture server on an ephemeral port, yields its base URL to
  # the block (which must perform a single request against it) and returns the
  # CapturedRequest. Pass ssl: true to terminate TLS using the test certificates.
  def capture_request(ssl: false)
    tcp = TCPServer.new('127.0.0.1', 0)
    port = tcp.addr[1]
    server = ssl ? wrap_tls(tcp) : tcp
    captured = nil
    acceptor = Thread.new do
      conn = server.accept
      captured = read_request(conn)
      conn.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      conn.close
    end
    yield "#{ssl ? 'https' : 'http'}://127.0.0.1:#{port}"
    acceptor.join(5)
    captured
  ensure
    tcp.close if tcp
  end

  private

  def wrap_tls(tcp)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = OpenSSL::X509::Certificate.new(File.read(File.join(CERT_DIR, 'cacert.pem')))
    ctx.key = OpenSSL::PKey.read(File.read(File.join(CERT_DIR, 'privkey.pem')))
    OpenSSL::SSL::SSLServer.new(tcp, ctx)
  end

  def read_request(conn)
    buf = +''
    buf << conn.readpartial(4096) until buf.include?("\r\n\r\n")
    head, rest = buf.split("\r\n\r\n", 2)
    request_line, *header_lines = head.split("\r\n")
    headers = header_lines.each_with_object({}) do |line, acc|
      name, value = line.split(': ', 2)
      acc[name.downcase] = value
    end
    # Honour Expect: 100-continue so the client proceeds to send the body.
    conn.write("HTTP/1.1 100 Continue\r\n\r\n") if headers['expect'].to_s =~ /100-continue/i
    CapturedRequest.new(request_line, headers, read_body(conn, headers, rest))
  end

  def read_body(conn, headers, rest)
    if headers['transfer-encoding'] == 'chunked'
      dechunk(drain_chunked(conn, rest))
    elsif (len = headers['content-length'])
      read_exactly(conn, len.to_i, rest)
    else
      rest
    end
  end

  def drain_chunked(conn, rest)
    buf = rest.dup
    buf << conn.readpartial(4096) until buf.include?("0\r\n\r\n")
    buf
  end

  def read_exactly(conn, n, rest)
    buf = rest.dup
    buf << conn.readpartial(4096) while buf.bytesize < n
    buf.byteslice(0, n)
  end

  def dechunk(buf)
    io = StringIO.new(buf)
    out = +''
    while (size_line = io.gets("\r\n"))
      size = size_line.strip.split(';', 2).first.to_i(16)
      break if size.zero?
      out << io.read(size).to_s
      io.read(2) # trailing CRLF
    end
    out
  end
end

RSpec.configure { |c| c.include RawRequestCapture }
