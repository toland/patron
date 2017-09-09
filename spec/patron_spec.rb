require File.expand_path("./spec") + '/spec_helper.rb'

describe Patron do

  it 'should return the user agent string' do
    ua_str = Patron.user_agent_string
    expect(ua_str).to include('curl')
    expect(ua_str).to include('Patron')
  end
  
  it "should return the version number of the Patron library" do
    version = Patron.version
    expect(version).to match(%r|^\d+.\d+.\d+$|)
  end

  it "should return the version string of the libcurl library" do
    version = Patron.libcurl_version
    expect(version).to match(%r|^libcurl/\d+.\d+.\d+|)
  end

  it "should return the version numbers of the libcurl library" do
    version = Patron.libcurl_version_exact
    expect(version.length).to eq(3)
    expect(version[0]).to be > 0
    expect(version[1]).to be >= 0
    expect(version[2]).to be >= 0
  end
end
