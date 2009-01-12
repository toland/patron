require File.dirname(__FILE__) + '/spec_helper.rb'
require 'patron/request'

describe Patron::Request do

  before(:each) do
    @curl = Patron::Request.new
  end

  it "should return the version number of the request library" do
    version = Patron::Request.version
    version.should be_kind_of(String)
  end

  it "should escape and unescape strings" do
    string = "foo~bar baz/"
    escaped = @curl.escape(string)
    unescaped = @curl.unescape(escaped)
    unescaped.should == string
  end

  it "should set and return the URL" do
    @curl.setopt(Patron::CurlOpts::URL, "http://thehive.com/")
    url = @curl.getinfo(Patron::CurlInfo::EFFECTIVE_URL)
    url.should == "http://thehive.com/"
  end

  it "should use proc to handle results" do
    pending "until a test web server is available"

    valid = false
    p = Proc.new {|data| valid = true}

    @curl.setopt(Patron::CurlOpts::URL, "http://thehive.com/")
    @curl.setopt(Patron::CurlOpts::WRITE_HANDLER, p)
    @curl.perform
    valid.should be_true
  end

end
