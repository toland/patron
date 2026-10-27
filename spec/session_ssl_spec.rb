# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

describe Patron::Session, :session do

  around(:each) do |example|
    Dir.mktmpdir('patron') do |dir|
      @tmpdir = dir
      example.run
    end
  end

  before(:each) do
    @session = Patron::Session.new
    @session.connect_timeout = 10 # the first TLS handshake with both ends under valgrind blows the 1 s default
    @session.base_url = "https://localhost:#{HTTPS_PORT}"
    @session.insecure = true
    # The first TLS handshake takes a few seconds when both ends run under valgrind
    @session.connect_timeout = 10
  end

  it "should retrieve a url with :get" do
    response = @session.get("/test")
    body = readback(response.body)
    expect(body.request_method).to be == "GET"
  end

  it "should download content with :get and a file path" do
    tmpfile = File.join(@tmpdir, "patron_test.json")
    response = @session.get_file "/test", tmpfile
    expect(response.body).to be_nil
    body = readback(File.open(tmpfile).read)
    expect(body.request_method).to be == "GET"
    FileUtils.rm tmpfile
  end

  # See https://github.com/curl/curl/issues/788
  # Basically any HTTPS operation crashes on OSX with securetransport-enabled libCURL
  it "should download content in a forked subprocess" do
    # To trigger the bug, we need to perform a request in the master process first
    tmpfile = File.join(@tmpdir, "patron_test.json")
    @session.get_file "/test", tmpfile
    FileUtils.rm tmpfile
    
    # and this one segfaults
    pid = fork do
      response = @session.get_file "/test", tmpfile
      expect(response.body).to be_nil
      body = readback(File.open(tmpfile).read)
      expect(body.request_method).to be == "GET"
      FileUtils.rm tmpfile
    end
    
    exit_pid, status = Process.wait2(pid)
    expect(status.exitstatus).to be_zero
  end
  
  it "should download correctly(md5 ok) with get_file" do
    tmpfile = File.join(@tmpdir, "picture")
    response = @session.get_file "/picture", tmpfile
    expect(response.body).to be_nil
    expect(File.size(File.join(__dir__, "support", "pic.png"))).to be == File.size(tmpfile)
    FileUtils.rm tmpfile
  end

  it "should include custom headers in a request" do
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = readback(response.body)
    expect(body.header["user-agent"]).to be == ["PatronTest"]
  end

  it "should merge custom headers with session headers" do
    @session.headers["X-Test"] = "Testing"
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = readback(response.body)
    expect(body.header["user-agent"]).to be == ["PatronTest"]
    expect(body.header["x-test"]).to be == ["Testing"]
  end

  it "should raise an exception on timeout" do
    @session.timeout = 1
    expect {
      @session.get("/timeout?millis=1100")
    }.to raise_error(Patron::TimeoutError)
  end

  it "should follow redirects by default" do
    @session.max_redirects = 1
    response = @session.get("/redirect")
    body = readback(response.body)
    expect(response.status).to be == 200
    expect(body.path).to be == "/test"
  end

  it "should include redirect count in response" do
    @session.max_redirects = 1
    response = @session.get("/redirect")
    expect(response.redirect_count).to be == 1
  end

  it "should not follow redirects when configured to do so" do
    @session.max_redirects = 0
    response = @session.get("/redirect")
    expect(response.status).to be == 301
    expect(response.body).to be_empty
  end

  it "should retrieve URL metadata with :head" do
    response = @session.head("/test")
    expect(response.status).to be == 200
    expect(response.body).to be_empty
    expect(response.headers).to_not be_empty
  end

  it "should send a delete request with :delete" do
    response = @session.delete("/test")
    body = readback(response.body)
    expect(body.request_method).to be == "DELETE"
  end

  it "should send a COPY request with :copy" do
    response = @session.copy("/test", "/test2")
    body = readback(response.body)
    expect(body.request_method).to be == "COPY"
  end

  it "should include a Destination header in COPY requests" do
    response = @session.copy("/test", "/test2")
    body = readback(response.body)
    expect(body.header['destination'].first).to be == "/test2"
  end

  it "should upload data with :get" do
    data = "upload data"
    response = @session.request(:get, "/test", {}, :data => data)
    body = readback(response.body)
    expect(body.request_method).to be == "GET"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should upload data with :put" do
    data = "upload data"
    response = @session.put("/test", data)
    body = readback(response.body)
    expect(body.request_method).to be == "PUT"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should raise when no data is provided to :put" do
    expect { @session.put("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :put" do
    response = @session.put_file("/test", "LICENSE")
    body = readback(response.body)
    expect(body.request_method).to be == "PUT"
  end

  it "should raise when no file is provided to :put" do
    expect { @session.put_file("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :put using chunked transfer-encoding" do
    # Transfer-Encoding is a hop-by-hop header (RFC 7230 3.3.1): a conformant server
    # decodes the chunked framing and never exposes the header to the application, so
    # we capture the raw request to assert how Patron actually frames the upload.
    captured = capture_request(ssl: true) do |url|
      session = Patron::Session.new
      session.base_url = url
      session.insecure = true
      session.timeout = 5
      session.put_file("/test", "LICENSE")
    end
    expect(captured.request_line).to start_with("PUT ")
    expect(captured.headers["transfer-encoding"]).to be == "chunked"
    expect(captured.headers).to_not have_key("content-length")
    expect(captured.body.bytesize).to be == File.size("LICENSE")
  end

  it "should upload data with :post" do
    data = "upload data"
    response = @session.post("/test", data)
    body = readback(response.body)
    expect(body.request_method).to be == "POST"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should post a hash of arguments as a urlencoded form" do
    data = {:foo => 123, 'baz' => '++hello world++'}
    response = @session.post("/testpost", data)
    body = readback(response.body)
    expect(body['content_type']).to be == "application/x-www-form-urlencoded"
    expect(body['body']).to match(/baz=%2B%2Bhello%20world%2B%2B/)
    expect(body['body']).to match(/foo=123/)
  end

  it "should raise when no data is provided to :post" do
    expect { @session.post("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :post" do
    response = @session.post_file("/test", "LICENSE")
    body = readback(response.body)
    expect(body.request_method).to be == "POST"
  end

  it "should upload a multipart with :post" do
    response = @session.post_multipart("/test", { :test_data => "123" }, { :test_file => "LICENSE" } )
    body = readback(response.body)
    expect(body.request_method).to be == "POST"
  end

  it "should raise when no file is provided to :post" do
    expect { @session.post_file("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :post using chunked transfer-encoding" do
    # See the :put counterpart above: Transfer-Encoding is hop-by-hop and invisible
    # to the application, so we capture the raw request to assert the framing.
    captured = capture_request(ssl: true) do |url|
      session = Patron::Session.new
      session.base_url = url
      session.insecure = true
      session.timeout = 5
      session.post_file("/test", "LICENSE")
    end
    expect(captured.request_line).to start_with("POST ")
    expect(captured.headers["transfer-encoding"]).to be == "chunked"
    expect(captured.headers).to_not have_key("content-length")
    expect(captured.body.bytesize).to be == File.size("LICENSE")
  end

  it "should handle cookies if set" do
    @session.handle_cookies
    response = @session.get("/setcookie").body
    expect(readback(response).header['cookie'].first).to be == "session_id=foo123"
  end

  it "should not handle cookies by default" do
    response = @session.get("/setcookie").body
    expect(readback(response).header).to_not include('cookie')
  end

  it "should raise exception if cookie store is not writable or readable" do
    expect { @session.handle_cookies("/trash/clash/foo") }.to raise_error(ArgumentError)
  end

  it "should work with multiple threads" do
    threads = []
    3.times do
      threads << Thread.new do
        session = Patron::Session.new
        session.base_url = "https://localhost:#{HTTPS_PORT}"
        session.insecure = true
        session.post_file("/test", "LICENSE")
      end
    end
    threads.each {|t| t.join }
  end

  it "should fail when insecure mode is off" do
    expect {
      @session.insecure = nil
      response = @session.get("/test")
    }.to raise_error(Patron::Error)
  end

  it "should work when insecure mode is off but certificate is supplied" do
    @session.insecure = nil
    @session.cacert = File.join(__dir__, 'support', 'certs', 'cacert.pem')
    response = @session.get("/test")
    body = readback(response.body)
    expect(body.request_method).to be == "GET"
  end

  it "should allow to specify insecure mode per-request" do
    @session.insecure = false
    expect {
      @session.request(:get, "/test", {}, insecure: true)
    }.not_to raise_error
    expect {
      @session.request(:get, "/test", {})
    }.to raise_error(Patron::Error)
  end

  it "should work with different SSL versions" do
    ['TLSv1', 'TLSv1_2'].each do |version|
      @session.ssl_version = version
      response = @session.get("/test")
      expect(response.status).to be == 200
    end
  end

  it "should raise when an unsupported or unknown SSL version is requested" do
    ['something', 1].each do |version|
      @session.ssl_version = version
      expect {
        @session.get("/test")
      }.to raise_error(Patron::UnsupportedSSLVersion)
    end
  end

  it "should work with different HTTP versions" do
    ['HTTPv1_0','HTTPv1_1'].each do |version|
      @session.http_version = version
      response = @session.get("/test")
      expect(response.status).to be == 200
    end
  end

  it "should raise when an unsupported or unknown HTTP version is requested" do
    ['something', 1].each do |version|
      @session.http_version = version
      expect {
        @session.get("/test")
      }.to raise_error(Patron::UnsupportedHTTPVersion)
    end
  end

  # ------------------------------------------------------------------------
  describe 'when debug is enabled' do
    it 'it should not clobber stderr' do
      rdev = STDERR.stat.rdev

      @session.enable_debug
      expect(STDERR.stat.rdev).to be == rdev

      @session.enable_debug
      expect(STDERR.stat.rdev).to be == rdev
    end
  end

  describe 'with a server that requires a client certificate' do
    let(:certs) { File.join(__dir__, 'support', 'certs') }

    # libcurl's GnuTLS backend reports any client certificate it can't load as CURLE_SSL_CONNECT_ERROR
    let(:gnutls) { Patron.libcurl_version.include?('GnuTLS') }

    def refused_by_server
      raise_error { |e|
        expect(e).to be_kind_of(Patron::Error)
        expect(e).not_to be_kind_of(Patron::ClientCertificateError)
        expect(e).not_to be_kind_of(Patron::TimeoutError)
      }
    end

    before(:each) do
      @session.base_url = "https://localhost:#{MTLS_PORT}"
      @session.insecure = false
      @session.cacert = File.join(certs, 'cacert.pem')
    end

    it "presents a PKCS#12 client certificate" do
      @session.ssl_cert = File.join(certs, 'client.p12')
      @session.ssl_cert_type = 'P12'
      @session.ssl_key_password = 'patron'
      response = @session.get("/peercert")
      expect(response.status).to be == 200
      expect(response.body).to include('CN=patron-test-client')
    end

    it "presents a PEM client certificate with a separate encrypted key" do
      @session.ssl_cert = File.join(certs, 'client_cert.pem')
      @session.ssl_cert_type = 'PEM'
      @session.ssl_key = File.join(certs, 'client_key.pem')
      @session.ssl_key_password = 'patron'
      response = @session.get("/peercert")
      expect(response.status).to be == 200
      expect(response.body).to include('CN=patron-test-client')
    end

    it "accepts the client certificate as a per-request option" do
      response = @session.request(:get, "/peercert", {},
        ssl_cert: File.join(certs, 'client.p12'), ssl_cert_type: 'P12', ssl_key_password: 'patron')
      expect(response.body).to include('CN=patron-test-client')
    end

    it "accepts Pathnames for the certificate and key and a Symbol for the type" do
      @session.cacert = Pathname(certs).join('cacert.pem')
      @session.ssl_cert = Pathname(certs).join('client_cert.pem')
      @session.ssl_cert_type = :PEM
      @session.ssl_key = Pathname(certs).join('client_key.pem')
      @session.ssl_key_password = 'patron'
      response = @session.get("/peercert")
      expect(response.body).to include('CN=patron-test-client')
    end

    it "does not leak a failed request's options into the next one" do
      @session.ssl_cert = File.join(certs, 'client.p12')
      @session.ssl_cert_type = 'P12'
      @session.ssl_key_password = 'patron'
      expect {
        @session.request(:get, "/test", {'X-Leaked' => 'yes'}, proxy_type: :not_a_proxy_type)
      }.to raise_error(TypeError)

      body = readback(@session.get("/test").body)
      expect(body.header).not_to have_key('x-leaked')
    end

    it "raises ClientCertificateError when the key password is wrong" do
      skip "GnuTLS does not tell this apart from a handshake failure" if gnutls
      @session.ssl_cert = File.join(certs, 'client.p12')
      @session.ssl_cert_type = 'P12'
      @session.ssl_key_password = 'wrong'
      expect { @session.get("/peercert") }.to raise_error(Patron::ClientCertificateError)
    end

    it "raises ClientCertificateError when the certificate file does not exist" do
      skip "GnuTLS does not tell this apart from a handshake failure" if gnutls
      @session.ssl_cert = File.join(certs, 'nonexistent.p12')
      @session.ssl_cert_type = 'P12'
      @session.ssl_key_password = 'patron'
      expect { @session.get("/peercert") }.to raise_error(Patron::ClientCertificateError)
    end

    it "fails when the server does not trust the client certificate" do
      @session.ssl_cert = File.join(certs, 'rogue_client.p12')
      @session.ssl_cert_type = 'P12'
      @session.ssl_key_password = 'patron'
      expect { @session.get("/peercert") }.to refused_by_server
    end

    it "fails when no client certificate is presented" do
      # Depending on the TLS version the server rejects us either during or right after the handshake
      expect { @session.get("/peercert") }.to refused_by_server
    end
  end
end
