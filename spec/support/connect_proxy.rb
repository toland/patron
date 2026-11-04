# frozen_string_literal: true

require 'socket'

# A bare-bones CONNECT-only HTTP proxy: answers "200 Connection established" and then
# relays bytes both ways. Enough for libcurl to tunnel an https request through it.
module ConnectProxy
  def with_connect_proxy
    server = TCPServer.new('127.0.0.1', 0)
    acceptor = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) { |c| tunnel(c) }
      end
    rescue IOError, Errno::EBADF
      # the listener got closed, we are done
    end
    yield "127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    acceptor&.join(2)
  end

  private

  def tunnel(client)
    request_line = client.gets
    nil while (line = client.gets) && line != "\r\n"
    host, port = request_line.split(' ')[1].split(':')
    upstream = TCPSocket.new(host, Integer(port))
    client.write("HTTP/1.1 200 Connection established\r\n\r\n")
    [Thread.new { relay(client, upstream) }, Thread.new { relay(upstream, client) }].each(&:join)
  rescue IOError, SystemCallError
    nil
  ensure
    client.close rescue nil
    upstream&.close rescue nil
  end

  def relay(from, to)
    IO.copy_stream(from, to)
  rescue IOError, SystemCallError
    nil
  ensure
    to.close_write rescue nil
  end
end

RSpec.configure { |c| c.include ConnectProxy }
