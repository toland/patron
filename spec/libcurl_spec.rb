require File.dirname(__FILE__) + '/spec_helper.rb'
require 'patron/libcurl'

describe Patron::Libcurl, "SPI" do

  before(:each) do
    @curl = Patron::Libcurl.new
  end

  it "should return the version number of the libcurl library" do
    version = Patron::Libcurl.version
    version.should be_kind_of(String)
  end

  it "should escape and unescape strings" do
    string = "foo~bar baz/"
    escaped = @curl.escape(string)
    unescaped = @curl.unescape(escaped)
    unescaped.should == string
  end

  it "should set and return the URL" do
    @curl.setopt(Patron::Libcurl::OPT_URL, "http://thehive.com/")
    url = @curl.getinfo(Patron::Libcurl::INFO_URL)
    url.should == "http://thehive.com/"
  end

  it "should use proc to handle results" do
    pending "until a test web server is available"

    valid = false
    p = Proc.new {|data| valid = true}

    @curl.setopt(Patron::Libcurl::OPT_URL, "http://thehive.com/")
    @curl.setopt(Patron::Libcurl::OPT_WRITE_HANDLER, p)
    @curl.perform
    valid.should be_true
  end

end
