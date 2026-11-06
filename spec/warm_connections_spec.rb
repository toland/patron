# frozen_string_literal: true

describe "Keeping connections warm", :session do
  let(:base_url) { "http://localhost:#{HTTP_PORT}" }
  let(:session) { Patron::Session.new(base_url: base_url, timeout: 10) }

  describe "connection info" do
    it "tells the HTTP version, the address and whether the connection was reused" do
      first = session.get("/test")
      second = session.get("/test")

      expect(first.connection).to be_a(Patron::ConnectionInfo)
      expect(first.connection.http_version).to eq("HTTP/1.1")
      expect(first.connection.ip).to match(/\A(127\.0\.0\.1|::1)\z/)
      expect(first.connection.port).to eq(HTTP_PORT)
      expect(first.connection.new_connections).to eq(1)
      expect(first.connection.reused?).to be(false)
      expect(first.connection_reused?).to be(false)

      expect(second.connection.new_connections).to eq(0)
      expect(second.connection_reused?).to be(true)
      expect(second.connection).to be_frozen
    end

    it "is on the stats of a stream as well" do
      session.get("/test")
      stats = session.get_stream("/test") { |s| s.read }
      expect(stats.connection.http_version).to eq("HTTP/1.1")
      expect(stats.connection_reused?).to be(true)
      expect(Ractor.shareable?(stats)).to be(true)
    end

    it "is nil on a Response built by hand, as webmock builds them" do
      response = Patron::Response.new(url: "http://x/", status: 200, header_data: "HTTP/1.1 200 OK\r\n\r\n")
      expect(response.connection).to be_nil
      expect(response.connection_reused?).to be_nil
      response = Patron::Response.new(url: "http://x/", status: 200, header_data: "HTTP/1.1 200 OK\r\n\r\n",
                                      connection: { http_version: "HTTP/2", ip: "::1", port: 443, new_connections: 0 })
      expect(response.connection.http_version).to eq("HTTP/2")
      expect(response.connection_reused?).to be(true)
      expect { Patron::Response.new(url: "http://x/", status: 200, header_data: "", connection: 42) }.to raise_error(ArgumentError)
    end
  end

  describe "warm_up" do
    it "opens the connection so that the first request reuses it" do
      expect(session.warm_up("/test")).to equal(session)
      expect(session.get("/test").connection_reused?).to be(true)
    end

    it "does not care about the status of the warm-up response" do
      session.warm_up("/no-such-path-at-all")
      expect(session.get("/test").connection_reused?).to be(true)
    end
  end

  describe "connection options" do
    it "are Session defaults and Request attributes with validation" do
      session = Patron::Session.new(max_connection_age: 3600, max_connection_lifetime: 86_400, tcp_keepalive: 30,
                                    resolve: { "example.com:80" => "127.0.0.1" })
      request = session.build_request(:get, "http://example.com/")
      expect(request.max_connection_age).to eq(3600)
      expect(request.max_connection_lifetime).to eq(86_400)
      expect(request.tcp_keepalive).to eq(30)
      expect(request.resolve).to eq("example.com:80" => "127.0.0.1")

      request = Patron::Request.new(tcp_keepalive: true)
      expect(request.tcp_keepalive).to eq(60)
      expect(Patron::Request.new(tcp_keepalive: false).tcp_keepalive).to be_nil
      expect(Patron::Request.new(max_connection_age: 0).max_connection_age).to eq(0)

      expect { Patron::Request.new(max_connection_age: -1) }.to raise_error(ArgumentError, /non-negative/)
      expect { Patron::Request.new(max_connection_lifetime: -5) }.to raise_error(ArgumentError, /non-negative/)
      expect { Patron::Request.new(tcp_keepalive: 0) }.to raise_error(ArgumentError, /positive/)
      expect { Patron::Request.new(resolve: ["a", "b"]) }.to raise_error(ArgumentError, /Hash/)
    end

    it "are accepted by libcurl and the request still works" do
      session = Patron::Session.new(base_url: base_url, timeout: 10, max_connection_age: 3600,
                                    max_connection_lifetime: 86_400, tcp_keepalive: 15)
      expect(session.get("/test").status).to eq(200)
      expect(session.get("/test").connection_reused?).to be(true)
    end

    it "pins a host name to an address with resolve" do
      # "patron-resolve.invalid" cannot be looked up, so this only works when the pin is honoured
      session = Patron::Session.new(base_url: "http://patron-resolve.invalid:#{HTTP_PORT}", timeout: 10,
                                    resolve: { "patron-resolve.invalid:#{HTTP_PORT}" => "127.0.0.1" })
      response = session.get("/test")
      expect(response.status).to eq(200)
      expect(response.connection.ip).to eq("127.0.0.1")
      expect(readback(response.body).header["host"]).to eq(["patron-resolve.invalid:#{HTTP_PORT}"])
      expect { Patron::Session.new(base_url: "http://patron-resolve.invalid:#{HTTP_PORT}", timeout: 10).get("/test") }
        .to raise_error(Patron::HostResolutionError)
    end
  end
end
