## -------------------------------------------------------------------
##
## Copyright (c) 2008 The Hive http://www.thehive.com/
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
## THE SOFTWARE.
##
## -------------------------------------------------------------------
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
    body.request_method.should == "GET"
  end

  it "should download content with :get and a file path" do
    tmpfile = "/tmp/patron_test.yaml"
    response = @session.get_file "/test", tmpfile
    response.body.should be_nil
    body = YAML::load_file(tmpfile)
    body.request_method.should == "GET"
    FileUtils.rm tmpfile
  end

  it "should download correctly(md5 ok) with get_file" do
    tmpfile = "/tmp/picture"
    response = @session.get_file "/picture", tmpfile
    response.body.should be_nil
    File.size(File.join(File.dirname(__FILE__),"../pic.png")).should == File.size(tmpfile)
    FileUtils.rm tmpfile
  end

  it "should include custom headers in a request" do
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = YAML::load(response.body)
    body.header["user-agent"].should == ["PatronTest"]
  end

  it "should merge custom headers with session headers" do
    @session.headers["X-Test"] = "Testing"
    response = @session.get("/test", {"User-Agent" => "PatronTest"})
    body = YAML::load(response.body)
    body.header["user-agent"].should == ["PatronTest"]
    body.header["x-test"].should == ["Testing"]
  end

  it "should raise an exception on timeout" do
    @session.timeout = 1
    lambda {@session.get("/timeout")}.should raise_error(Patron::TimeoutError)
  end

  it "should follow redirects by default" do
    @session.max_redirects = 1
    response = @session.get("/redirect")
    body = YAML::load(response.body)
    response.status.should == 200
    body.path.should == "/test"
  end

  it "should include redirect count in response" do
    @session.max_redirects = 1
    response = @session.get("/redirect")
    response.redirect_count.should == 1
  end

  it "should not follow redirects when configured to do so" do
    @session.max_redirects = 0
    response = @session.get("/redirect")
    response.status.should == 301
    response.body.should be_empty
  end

  it "should retrieve URL metadata with :head" do
    response = @session.head("/test")
    response.status.should == 200
    response.body.should be_empty
    response.headers.should_not be_empty
  end

  it "should send a delete request with :delete" do
    response = @session.delete("/test")
    body = YAML::load(response.body)
    body.request_method.should == "DELETE"
  end

  it "should send a COPY request with :copy" do
    response = @session.copy("/test", "/test2")
    body = YAML::load(response.body)
    body.request_method.should == "COPY"
  end

  it "should include a Destination header in COPY requests" do
    response = @session.copy("/test", "/test2")
    body = YAML::load(response.body)
    body.header['destination'].first.should == "/test2"
  end

  it "should upload data with :get" do
    data = "upload data"
    response = @session.request(:get, "/test", {}, :data => data)
    body = YAML::load(response.body)
    body.request_method.should == "GET"
    body.header['content-length'].should == [data.size.to_s]
  end

  it "should upload data with :put" do
    data = "upload data"
    response = @session.put("/test", data)
    body = YAML::load(response.body)
    body.request_method.should == "PUT"
    body.header['content-length'].should == [data.size.to_s]
  end

  it "should raise when no data is provided to :put" do
    lambda { @session.put("/test", nil) }.should raise_error(ArgumentError)
  end

  it "should upload a file with :put" do
    response = @session.put_file("/test", "LICENSE")
    body = YAML::load(response.body)
    body.request_method.should == "PUT"
  end

  it "should raise when no file is provided to :put" do
    lambda { @session.put_file("/test", nil) }.should raise_error(ArgumentError)
  end

  it "should use chunked encoding when uploading a file with :put" do
    response = @session.put_file("/test", "LICENSE")
    body = YAML::load(response.body)
    body.header['transfer-encoding'].first.should == "chunked"
  end

  it "should upload data with :post" do
    data = "upload data"
    response = @session.post("/test", data)
    body = YAML::load(response.body)
    body.request_method.should == "POST"
    body.header['content-length'].should == [data.size.to_s]
  end

  it "should post a hash of arguments as a urlencoded form" do
    data = {:foo => 123, 'baz' => '++hello world++'}
    response = @session.post("/testpost", data)
    body = YAML::load(response.body)
    body['content_type'].should == "application/x-www-form-urlencoded"
    body['body'].should match(/baz=%2B%2Bhello%20world%2B%2B/)
    body['body'].should match(/foo=123/)
  end

  it "should raise when no data is provided to :post" do
    lambda { @session.post("/test", nil) }.should raise_error(ArgumentError)
  end

  it "should upload a file with :post" do
    response = @session.post_file("/test", "LICENSE")
    body = YAML::load(response.body)
    body.request_method.should == "POST"
  end

  it "should upload a multipart with :post" do
    response = @session.post_multipart("/test", { :test_data => "123" }, { :test_file => "LICENSE" } )
    body = YAML::load(response.body)
    body.request_method.should == "POST"
  end

  it "should raise when no file is provided to :post" do
    lambda { @session.post_file("/test", nil) }.should raise_error(ArgumentError)
  end

  it "should use chunked encoding when uploading a file with :post" do
    response = @session.post_file("/test", "LICENSE")
    body = YAML::load(response.body)
    body.header['transfer-encoding'].first.should == "chunked"
  end

  it "should handle cookies if set" do
    @session.handle_cookies
    response = @session.get("/setcookie").body
    YAML::load(response).header['cookie'].first.should == "session_id=foo123"
  end

  it "should not handle cookies by default" do
    response = @session.get("/setcookie").body
    YAML::load(response).header.should_not include('cookie')
  end

  it "should ignore a wrong Content-Length when asked to" do
    lambda {
      @session.ignore_content_length = true
      @session.get("/wrongcontentlength")
    }.should_not raise_error
  end

  it "should fail by default with a Content-Length too high" do
    lambda {
      @session.ignore_content_length = nil
      @session.get("/wrongcontentlength")
    }.should raise_error(Patron::PartialFileError)
  end

  it "should raise exception if cookie store is not writable or readable" do
    lambda { @session.handle_cookies("/trash/clash/foo") }.should raise_error(ArgumentError)
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
    lambda {
      @session.insecure = nil
      response = @session.get("/test")
    }.should raise_error(Patron::Error)
  end

  it "should work when insecure mode is off but certificate is supplied" do
    @session.insecure = nil
    @session.cacert = 'spec/certs/cacert.pem'
    response = @session.get("/test")
    body = YAML::load(response.body)
    body.request_method.should == "GET"
  end

  # ------------------------------------------------------------------------
  describe 'when debug is enabled' do
    it 'it should not clobber stderr' do
      rdev = STDERR.stat.rdev

      @session.enable_debug
      STDERR.stat.rdev.should be == rdev

      @session.enable_debug
      STDERR.stat.rdev.should be == rdev
    end
  end

end
