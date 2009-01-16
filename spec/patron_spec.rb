require File.dirname(__FILE__) + '/spec_helper.rb'

describe Patron do

  it "should return the version number of the Patron library" do
    version = Patron.version
    version.should match(%r|^\d+.\d+.\d+$|)
  end

  it "should return the version number of the libcurl library" do
    version = Patron.libcurl_version
    version.should match(%r|^libcurl/\d+.\d+.\d+|)
  end

end
