require File.expand_path("./spec") + '/spec_helper.rb'
require 'webrick'
require 'yaml'
require 'base64'
require 'fileutils'

describe Patron::Session do

  before(:each) do
    @session = Patron::Session.new
    @session.base_url = "https://localhost:9043"
    @session.insecure = true
  end

  it "should retrieve a url with :get" do
    response = @session.get("/test")
    body = YAML::load(response.body)
    expect(body.request_method).to be == "GET"
  end

  it "should download content with :get and a file path" do
    tmpfile = "/tmp/patron_test.yaml"
    response = @session.get_file "/test", tmpfile
    expect(response.body).to be_nil
    body = YAML::load_file(tmpfile)
    expect(body.request_method).to be == "GET"
    FileUtils.rm tmpfile
  end

  # See https://github.com/curl/curl/issues/788
  # Basically any HTTPS operation crashes on OSX with securetransport-enabled libCURL
  it "should download content in a forked subprocess" do
    # To trigger the bug, we need to perform a request in the master process first
    tmpfile = "/tmp/patron_test.yaml"
    @session.get_file "/test", tmpfile
    FileUtils.rm tmpfile
    
    # and this one segfaults
    pid = fork do
      response = @session.get_file "/test", tmpfile
      expect(response.body).to be_nil
      body = YAML::load_file(tmpfile)
      expect(body.request_method).to be == "GET"
      FileUtils.rm tmpfile
    end
    
    exit_pid, status = Process.wait2(pid)
    expect(status.exitstatus).to be_zero
  end
  
  it "should download correctly(md5 ok) with get_file" do
    tmpfile = "/tmp/picture"
    response = @session.get_file "/picture", tmpfile
    expect(response.body).to be_nil
    expect(File.size(File.join(File.dirname(__FILE__),"../pic.png"))).to be == File.size(tmpfile)
    FileUtils.rm tmpfile
  end

  it "should include custom headers in a request" do
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = YAML::load(response.body)
    expect(body.header["user-agent"]).to be == ["PatronTest"]
  end

  it "should merge custom headers with session headers" do
    @session.headers["X-Test"] = "Testing"
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = YAML::load(response.body)
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
    body = YAML::load(response.body)
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
    body = YAML::load(response.body)
    expect(body.request_method).to be == "DELETE"
  end

  it "should send a COPY request with :copy" do
    response = @session.copy("/test", "/test2")
    body = YAML::load(response.body)
    expect(body.request_method).to be == "COPY"
  end

  it "should include a Destination header in COPY requests" do
    response = @session.copy("/test", "/test2")
    body = YAML::load(response.body)
    expect(body.header['destination'].first).to be == "/test2"
  end

  it "should upload data with :get" do
    data = "upload data"
    response = @session.request(:get, "/test", {}, :data => data)
    body = YAML::load(response.body)
    expect(body.request_method).to be == "GET"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should upload data with :put" do
    data = "upload data"
    response = @session.put("/test", data)
    body = YAML::load(response.body)
    expect(body.request_method).to be == "PUT"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should raise when no data is provided to :put" do
    expect { @session.put("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :put" do
    response = @session.put_file("/test", "LICENSE")
    body = YAML::load(response.body)
    expect(body.request_method).to be == "PUT"
  end

  it "should raise when no file is provided to :put" do
    expect { @session.put_file("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should use chunked encoding when uploading a file with :put" do
    response = @session.put_file("/test", "LICENSE")
    body = YAML::load(response.body)
    expect(body.header['transfer-encoding'].first).to be == "chunked"
  end

  it "should upload data with :post" do
    data = "upload data"
    response = @session.post("/test", data)
    body = YAML::load(response.body)
    expect(body.request_method).to be == "POST"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should post a hash of arguments as a urlencoded form" do
    data = {:foo => 123, 'baz' => '++hello world++'}
    response = @session.post("/testpost", data)
    body = YAML::load(response.body)
    expect(body['content_type']).to be == "application/x-www-form-urlencoded"
    expect(body['body']).to match(/baz=%2B%2Bhello%20world%2B%2B/)
    expect(body['body']).to match(/foo=123/)
  end

  it "should raise when no data is provided to :post" do
    expect { @session.post("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :post" do
    response = @session.post_file("/test", "LICENSE")
    body = YAML::load(response.body)
    expect(body.request_method).to be == "POST"
  end

  it "should upload a multipart with :post" do
    response = @session.post_multipart("/test", { :test_data => "123" }, { :test_file => "LICENSE" } )
    body = YAML::load(response.body)
    expect(body.request_method).to be == "POST"
  end

  it "should raise when no file is provided to :post" do
    expect { @session.post_file("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should use chunked encoding when uploading a file with :post" do
    response = @session.post_file("/test", "LICENSE")
    body = YAML::load(response.body)
    expect(body.header['transfer-encoding'].first).to be == "chunked"
  end

  it "should handle cookies if set" do
    @session.handle_cookies
    response = @session.get("/setcookie").body
    expect(YAML::load(response).header['cookie'].first).to be == "session_id=foo123"
  end

  it "should not handle cookies by default" do
    response = @session.get("/setcookie").body
    expect(YAML::load(response).header).to_not include('cookie')
  end

  it "should raise exception if cookie store is not writable or readable" do
    expect { @session.handle_cookies("/trash/clash/foo") }.to raise_error(ArgumentError)
  end

  it "should work with multiple threads" do
    threads = []
    3.times do
      threads << Thread.new do
        session = Patron::Session.new
        session.base_url = "https://localhost:9043"
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
    body = YAML::load(response.body)
    expect(body.request_method).to be == "GET"
  end

  it "should work with different SSL versions" do
    ['TLSv1_0','TLSv1_1'].each do |version|
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

end
