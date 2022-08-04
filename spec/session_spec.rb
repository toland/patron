require File.expand_path("./spec") + '/spec_helper.rb'
require 'webrick'
require 'yaml'
require 'base64'
require 'fileutils'
require 'securerandom'

describe Patron::Session do

  def yaml_load(str)
    if RUBY_VERSION >= '3.1.0'
      YAML::safe_load(str, permitted_classes: [OpenStruct])
    else
      YAML::load(str)
    end
  end

  before(:each) do
    @session = Patron::Session.new
    @session.base_url = "http://localhost:9001"
  end

  context 'when trying a non-HTTP(s) URL' do
    forbidden_protos = %w( smb tftp imap smtp telnet dict ftp sftp scp file gopher )
    forbidden_protos.each do |forbidden_proto|
      it "should deny a #{forbidden_proto.upcase} request" do
        expect {
          @session.base_url = '%s://localhost' % forbidden_proto
          @session.get('')
        }.to raise_error(Patron::UnsupportedProtocol)
      end
    end
  end
  
  it 'does not follow a redirect to a non-HTTP/HTTPS URL' do
    # The "/evil-redirect" servlet tries to do a redirect to SMTP,
    # which can lead to exploits. By default, libCURL will just follow
    # that redirect.
    expect {
      @session.get('/evil-redirect')
    }.to raise_error(Patron::UnsupportedProtocol)
  end
  
  it "should work when forcing ipv4" do
    @session.force_ipv4 = true
    expect { @session.get("/test") }.to_not raise_error
  end
  
  describe '.escape and #escape' do
    it 'makes escape() and unescape() available on the class' do
      string = "foo~bar baz/"
      escaped = described_class.escape(string)
      unescaped = described_class.unescape(escaped)
      expect(unescaped).to be == string
    end
    
    it "should escape and unescape strings symetrically" do
      string = "foo~bar baz/"
      escaped = @session.escape(string)
      unescaped = @session.unescape(escaped)
      expect(unescaped).to be == string
    end
  
    it "should make e and unescape strings symetrically" do
      string = "foo~bar baz/"
      escaped = @session.escape(string)
      unescaped = @session.unescape(escaped)
      expect(unescaped).to be == string
    end
  end
  
  it "should raise an error when passed an invalid action" do
    expect { @session.request(:bogus, "/test", {}) }.to raise_error(ArgumentError)
  end

  it "should raise an error when no URL is provided" do
    @session.base_url = nil
    expect {@session.get(nil)}.to raise_error(ArgumentError)
  end

  it "should retrieve a url with :get" do
    response = @session.get("/test")
    body = yaml_load(response.body)
    expect(body.request_method).to be == "GET"
  end

  it "should use full base url" do
    @session.base_url = "http://localhost:9001/api/v1"
    response = @session.get("/test")
    expect(response.url).to be == "http://localhost:9001/api/v1/test"
  end

  it 'should ignore #base_url when a full URL is provided' do
    @session.base_url = "http://example.com:123"
    expect { @session.get("http://localhost:9001/test") }.to_not raise_error(URI::InvalidURIError)
  end

  it "should download content with :get and a file path" do
    tmpfile = "/tmp/patron_test.yaml"
    response = @session.get_file "/test", tmpfile
    expect(response.body).to be_nil
    body = yaml_load(File.open(tmpfile).read)
    expect(body.request_method).to be == "GET"
    FileUtils.rm tmpfile
  end

  it "should download correctly(md5 ok) with get_file" do
    tmpfile = "/tmp/picture"
    response = @session.get_file "/picture", tmpfile
    expect(response.body).to be_nil
    expect(File.size(File.join(File.dirname(__FILE__),"../pic.png"))).to be == File.size(tmpfile)
    FileUtils.rm tmpfile
  end

  it "should follow a 307 redirect with Range headers" do
    tmpfile = "/tmp/picture-fragment"
    response = @session.get_file "/redirect-to-picture", tmpfile, {'Range' => 'bytes=0-3'}
    expect(response.body).to be_nil
    expect(File.size(tmpfile)).to eq(4)
    FileUtils.rm tmpfile
  end

  it "downloads a very large file" do
    tmpfile = "/tmp/large-succeeded"
    @session.get_file "/very-large", tmpfile
    expect(File.size(tmpfile)).to eq(15 * 1024 * 1024)
  end

  it "raises an exception if the download body limit is exceeded when using direct-to-file download" do
    tmpfile = "/tmp/large-aborted"
    @session.download_byte_limit = 1024
    @session.buffer_size = 1024
    expect {
      @session.get_file "/very-large", tmpfile
    }.to raise_error(Patron::Error)
    # On Ruby 2.x Patron::Aborted takes precedence, but
    # on 1.9 it will be Patron::PartialFileError
    expect(File.size(tmpfile)).to be < (1024 * 3)
  end

  it "raises an exception if the download body limit is exceeded when using download-to-memory" do
    @session.download_byte_limit = 1024
    @session.buffer_size = 1024
    expect {
      @session.get "/very-large"
    }.to raise_error(Patron::Error)
    # On Ruby 2.x Patron::Aborted takes precedence, but
    # on 1.9 it will be Patron::PartialFileError
  end

  it "should not send the user-agent if it has been deleted from headers" do
    @session.headers.delete 'User-Agent'
    response = @session.get("/test")
    body = yaml_load(response.body)
    expect(body.header["user-agent"]).to be_nil
  end
  
  it "should set the default User-agent" do
    response = @session.get("/test")
    body = yaml_load(response.body)
    expect(body.header["user-agent"]).to be == [Patron.user_agent_string]
  end

  it "should include custom headers in a request" do
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = yaml_load(response.body)
    expect(body.header["user-agent"]).to be == ["PatronTest"]
  end

  it "should include default headers in a request, if they were defined" do
    @session.headers = {"User-Agent" => "PatronTest"}
    response = @session.get("/test")
    body = yaml_load(response.body)
    expect(body.header["user-agent"]).to be == ["PatronTest"]
  end

  it "should merge custom headers with session headers" do
    @session.headers["X-Test"] = "Testing"
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = yaml_load(response.body)
    expect(body.header["user-agent"]).to be == ["PatronTest"]
    expect(body.header["x-test"]).to be == ["Testing"]
  end

  it "accepts the DNS cache timeout option" do
    @session.dns_cache_timeout = 60
    @session.get("/")
  end

  it "should raise an exception on timeout" do
    @session.timeout = 1
    expect {@session.get("/timeout?millis=1100")}.to raise_error(Patron::TimeoutError)
  end

  it "should raise an exception on a sub-second timeout" do
    @session.timeout = 0.3
    expect {@session.get("/timeout?millis=400")}.to raise_error(Patron::TimeoutError)
  end

  it "should raise an exception on timeout when reading from a slow resource and low speed limit is set" do
    @session.timeout = 10 # Greater than the low_speed_time
    @session.low_speed_time = 2
    @session.low_speed_limit = 10

    # Our test server starts sending the body only after 5 seconds. We should be able to abort
    # by exceeding the low_speed_time.
    started = Time.now.to_f
    expect {@session.get("/slow")}.to raise_error(Patron::TimeoutError)
    delta_s = Time.now.to_f - started
    # For some reason libCURL times out after 3 seconds instead of 2 sometimes.
    expect(delta_s).to be_within(0.1).of(2).or be_within(0.1).of(3)
  end

  it "is able to terminate the thread that is running a slow request using Thread#kill (uses the custom unblock)" do
    t = Thread.new do
      session = Patron::Session.new
      session.timeout = 10 # Greater than the sleep duration
      session.base_url = "http://localhost:9001"
      session.get("/slow")
    end

    # Our test server starts sending the body only after 5 seconds. We should be able to abort
    # using a signal during that time.
    started = Time.now.to_f
    sleep 2 # Less than what it takes for the server to respond
    t.kill # Kill the thread forcibly
    t.join # wrap up the thread. If Patron is still busy there, this join call will still take another 1s.

    delta_s = Time.now.to_f - started
    # For some reason libCURL times out after 3 seconds instead of 2 sometimes.
    expect(delta_s).to be_within(0.1).of(2).or be_within(0.1).of(3)
  end

  it "is able to terminate the process that is running a slow request with SIGINT" do
    pid = Process.fork do
      trap('SIGINT') do
        exit # exit the process
      end
      session = Patron::Session.new
      session.timeout = 10 # Greater than the sleep duration
      session.base_url = "http://localhost:9001"
      session.get("/slow")
    end

    # Our test server starts sending the body only after 5 seconds. We should be able to abort
    # using a signal during that time.
    started = Time.now.to_f
    sleep 2 # Less than what it takes for the server to respond
    Process.kill("INT", pid) # Signal the process...
    Process.wait(pid) # wrap up the process. If Patron is still busy there, this call will still take another 1s.
    delta_s = Time.now.to_f - started
    # For some reason libCURL times out after 3 seconds instead of 2 sometimes.
    expect(delta_s).to be_within(0.1).of(2).or be_within(0.1).of(3)
  end

  it "receives progress callbacks" do
    session = Patron::Session.new
    session.timeout = 10 # # Greater than the /slow respond time (5 seconds)
    session.base_url = "http://localhost:9001"
    callback_args = []
    session.progress_callback = Proc.new {|dltotal, dlnow, ultotal, ulnow|
      callback_args << [dltotal, dlnow, ultotal, ulnow]
    }
    session.get("/slow")
    expect(callback_args).not_to be_empty

    # Make sure that the callback setting was not reset.
    callback_args = []
    session.get("/slow")
    expect(callback_args).not_to be_empty
  end

  it "should follow redirects by default" do
    @session.max_redirects = 1
    response = @session.get("/redirect")
    body = yaml_load(response.body)
    expect(response.status).to be == 200
    expect(body.path).to be == "/test"
  end

  it "should not keep the Location header from the redirecting response" do
    @session.max_redirects = 1
    response = @session.get("/redirect")
    expect(response.headers['Location']).to be_nil
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
    body = yaml_load(response.body)
    expect(body.request_method).to be == "DELETE"
  end

  it "should send a COPY request with :copy" do
    response = @session.copy("/test", "/test2")
    body = yaml_load(response.body)
    expect(body.request_method).to be == "COPY"
  end

  it "should include a Destination header in COPY requests" do
    response = @session.copy("/test", "/test2")
    body = yaml_load(response.body)
    expect(body.header['destination'].first).to be == "/test2"
  end

  it "should upload data with :get" do
    data = "upload data"
    response = @session.request(:get, "/test", {}, :data => data)
    body = yaml_load(response.body)
    expect(body.request_method).to be == "GET"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end
  
  it "should call to_s on the data being uploaded via GET if it is not already a String" do
    data = 12345
    response = @session.request(:get, "/test", {}, :data => data)
    body = yaml_load(response.body)
    expect(body.request_method).to be == "GET"
  end
  
  it "should upload data with :get" do
    # Sending a request body with a GET request is a technique seldom used,
    # but it does get used nevertheless - for instance, it is a usual
    # practice when interacting with an ElasticSearch cluster where
    # you can have very deeply going queries, which are still technically GETs
    data = Random.new.bytes(1024 * 24)
    response = @session.request(:get, "/test", {}, :data => data)
    body = yaml_load(response.body)
    expect(body.request_method).to be == "GET"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end
  
  it "should upload data with :put" do
    data = Random.new.bytes(1024 * 24)
    response = @session.put("/test", data)
    body = yaml_load(response.body)
    expect(body.request_method).to be == "PUT"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should upload a Tempfile with :put" do
    data = Tempfile.new 'data-buffer'
    data << Random.new.bytes(1024 * 64)
    data.flush; data.rewind
    
    response = @session.put("/test", data, {'Expect' => ''})
    body = yaml_load(response.body)
    expect(body.request_method).to be == "PUT"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end
  
  it "should upload data with :patch" do
    data = "upload data"
    response = @session.patch("/testpatch", data)
    body = yaml_load(response.body)
    expect(body.body).to eq("upload data")
  end

  it "should upload data with :delete" do
    data = "upload data"
    response = @session.request(:delete, "/test", {}, :data => data)
    body = yaml_load(response.body)
    expect(body.request_method).to be == "DELETE"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should raise when no data is provided to :put" do
    expect { @session.put("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :put" do
    response = @session.put_file("/test", "LICENSE")
    body = yaml_load(response.body)
    expect(body.request_method).to be == "PUT"
  end

  it "should raise when no file is provided to :put" do
    expect { @session.put_file("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should use chunked encoding when uploading a file with :put" do
    response = @session.put_file("/test", "LICENSE")
    body = yaml_load(response.body)
    expect(body.header['transfer-encoding'].first).to be == "chunked"
  end
  
  it "should call to_s on the data being uploaded via POST if it is not already a String" do
    data = 12345
    response = @session.post("/testpost", data)
    body = yaml_load(response.body)
    expect(body['body']).to eq("12345")
  end
  
  it "should upload data with :post" do
    data = "upload data"
    response = @session.post("/test", data)
    body = yaml_load(response.body)
    expect(body.request_method).to be == "POST"
    expect(body.header['content-length']).to be == [data.size.to_s]
  end

  it "should POST a hash of arguments as a urlencoded form" do
    data = {:foo => 123, 'baz' => '++hello world++'}
    response = @session.post("/testpost", data)
    body = yaml_load(response.body)
    expect(body['content_type']).to be == "application/x-www-form-urlencoded"
    expect(body['body']).to match(/baz=%2B%2Bhello%20world%2B%2B/)
    expect(body['body']).to match(/foo=123/)
  end

  it "should raise when no data is provided to :post" do
    expect { @session.post("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should upload a file with :post" do
    response = @session.post_file("/test", "LICENSE")
    body = yaml_load(response.body)
    expect(body.request_method).to be == "POST"
  end

  it "should upload a multipart with :post" do
    response = @session.post_multipart("/test", { :test_data => "123" }, { :test_file => "LICENSE" } )
    body = yaml_load(response.body)
    expect(body.request_method).to be == "POST"
  end

  it "should raise when no file is provided to :post" do
    expect { @session.post_file("/test", nil) }.to raise_error(ArgumentError)
  end

  it "should use chunked encoding when uploading a file with :post" do
    response = @session.post_file("/test", "LICENSE")
    body = yaml_load(response.body)
    expect(body.header['transfer-encoding'].first).to be == "chunked"
  end

  it "should pass credentials as http basic auth" do
    @session.username = "foo"
    @session.password = "bar"
    response = @session.get("/test")
    body = yaml_load(response.body)
    expect(body.header['authorization']).to be == [encode_authz("foo", "bar")]
  end

  it "should store cookies across multiple requests" do
    tf = Tempfile.new('cookiejar')
    tf.close
    cookie_jar_path = tf.path
    
    @session.handle_cookies(cookie_jar_path)
    response = @session.get("/setcookie").body
    
    cookie_jar_contents = tf.open.read
    tf.unlink
    expect(cookie_jar_contents).not_to be_empty
    expect(cookie_jar_contents).to include('Netscape HTTP Cookie File')
  end
  
  it "should handle cookies if set" do
    @session.handle_cookies
    response = @session.get("/setcookie").body
    expect(yaml_load(response).header['cookie'].first).to be == "session_id=foo123"
  end

  it "should not handle cookies by default" do
    response = @session.get("/setcookie").body
    expect(yaml_load(response).header).to_not include('cookie')
  end

  it "should ignore a wrong Content-Length when asked to" do
    expect {
      @session.ignore_content_length = true
      @session.get("/wrongcontentlength", { 'Connection' => 'close' })
    }.to_not raise_error
  end

  it "should fail by default with a Content-Length too high" do
    expect {
      @session.ignore_content_length = nil
      @session.get("/wrongcontentlength", { 'Connection' => 'close' })
    }.to raise_error(Patron::PartialFileError)
  end

  it "should raise exception if cookie store is not writable or readable" do
    expect { @session.handle_cookies("/trash/clash/foo") }.to raise_error(ArgumentError)
  end

  it "should work with multiple threads" do
    threads = []
    3.times do
      threads << Thread.new do
        session = Patron::Session.new
        session.base_url = "http://localhost:9001"
        session.post_file("/test", "LICENSE")
      end
    end
    threads.each {|t| t.join }
  end

  it "should limit the buffer_size" do
    # Buffer size is tricky to test, as it only affects the buffer size for each
    # read and it's not really visible at this, higher level. It's also only a
    # suggestion rather than a command so it may not even take affect. Currently
    # we just test that the response completes without any issues, it would be nice
    # to have a more robust test here.
    @session.buffer_size = 1

    body = nil

    expect {
      response = @session.get("/test")
      body = yaml_load(response.body)
    }.to_not raise_error

    expect(body.request_method).to be == "GET"
  end

  it "should automatically decompress using Content-Encoding if requested" do
    @session.automatic_content_encoding = true
    response = @session.get('/gzip-compressed')
    
    expect(response.headers['Content-Length']).to eq('125')
    
    body = response.body
    expect(body).to match(/Some highly compressible data/)
    expect(body.bytesize).to eq(29696)
  end
  
  it "should serialize query params and append them to the url" do
    response = @session.request(:get, "/test", {}, :query => {:foo => "bar"})
    request = yaml_load(response.body)
    expect(request.path + '?' + request.query_string).to be == "/test?foo=bar"
  end

  it "should merge parameters in the :query option with pre-existing query parameters" do
    response = @session.request(:get, "/test?foo=bar", {}, :query => {:baz => "quux"})
    request = yaml_load(response.body)
    expect(request.path + '?' + request.query_string).to be == "/test?foo=bar&baz=quux"
  end

  def encode_authz(user, passwd)
    "Basic " + Base64.encode64("#{user}:#{passwd}").strip
  end

  describe 'when using a subclass with a custom Response' do
    
    class CustomResponse
      attr_reader :constructor_args
      def initialize(*constructor_args)
        @constructor_args = constructor_args
      end
    end
    
    class CustomizedSession < Patron::Session
      def response_class
        CustomResponse
      end
    end
    
    it 'instantiates the customized response object' do
      @session = CustomizedSession.new
      @session.base_url = "http://localhost:9001"
      response = @session.request(:get, "/test", {}, :query => {:foo => "bar"})
      
      expect(response).to be_kind_of(CustomResponse)
      expect(response.constructor_args.length).to eq(6)
    end
  end
  
  describe 'when instantiating with hash arguments' do

    let(:args) { {
        :timeout => 10,
        :dns_cache_timeout => 10,
        :base_url => 'http://localhost:9001',
        :headers => {'User-Agent' => 'myapp/1.0'}
    } }

    let(:session) { Patron::Session.new(args) }

    it 'sets the base_url' do
      expect(session.base_url).to be == args[:base_url]
    end

    it 'sets timeout' do
      expect(session.timeout).to be == args[:timeout]
    end

    it 'sets DNS cache timeout' do
      expect(session.dns_cache_timeout).to be == args[:dns_cache_timeout]
    end

    it 'sets headers' do
      expect(session.headers).to be == args[:headers]
    end

    context 'when given an incorrect accessor name' do
      let(:args) { { :not_a_real_accessor => 'http://localhost:9001' }}
      it 'raises no method error' do
        expect { session }.to raise_error NoMethodError
      end
    end

  end

  describe 'when instantiating with a block' do
    args = {
        :timeout => 10,
        :base_url => 'http://localhost:9001',
        :headers => {'User-Agent' => 'myapp/1.0'}
    }

    session = Patron::Session.new do |patron|
      patron.timeout = args[:timeout]
      patron.base_url = args[:base_url]
      patron.headers = args[:headers]
    end

    it 'sets the base_url' do
      expect(session.base_url).to be == args[:base_url]
    end

    it 'sets timeout' do
      expect(session.timeout).to be == args[:timeout]
    end

    it 'sets headers' do
      expect(session.headers).to be == args[:headers]
    end

    context 'when given an incorrect accessor name' do
      it 'raises no method error' do
        expect {
          Patron::Session.new do |patron|
            patron.timeoutttt = args[:timeout]
          end
        }.to raise_error NoMethodError
      end
    end
  end

  # ------------------------------------------------------------------------
  describe 'when debug is enabled' do
    it 'it should not clobber stderr' do
      rdev = STDERR.stat.rdev

      retval = @session.enable_debug
      expect(retval).to eq(@session)
      expect(STDERR.stat.rdev).to be == rdev

      retval = @session.enable_debug
      expect(retval).to eq(@session)
      expect(STDERR.stat.rdev).to be == rdev
    end
  end

end
