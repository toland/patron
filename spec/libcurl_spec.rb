require File.dirname(__FILE__) + '/spec_helper.rb'
require 'patron/libcurl'

describe Patron::Libcurl, "SPI" do

  it "should return 10 from the test1 method" do
    curl = Patron::Libcurl.new
    curl.test1.should == 10
  end

end
