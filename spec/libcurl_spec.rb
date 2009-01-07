require File.dirname(__FILE__) + '/spec_helper.rb'
require 'patron/libcurl'

describe Patron::Libcurl, "SPI" do

  it "should set and return the URL" do
    curl = Patron::Libcurl.new
    curl.setopt(Patron::Libcurl::OPT_URL, "http://thehive.com/")
    url = curl.getinfo(Patron::Libcurl::INFO_URL)
    url.should == "http://thehive.com/"
  end

end
