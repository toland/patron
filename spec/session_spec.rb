require File.dirname(__FILE__) + '/spec_helper.rb'


describe Patron::Session do

  before(:each) do
    @session = Patron::Session.new
    @session.base_url = "http://localhost:9001"
  end

  it "should escape and unescape strings" do
    string = "foo~bar baz/"
    escaped = @session.escape(string)
    unescaped = @session.unescape(escaped)
    unescaped.should == string
  end

  it "should get a url" do
    response = @session.get("/test")
    response.status.should == 200
  end

  it "should get a url with custom headers" do
    @session.headers["User-Agent"] = "PatronTest"
    response = @session.get("/test")
    response.status.should == 200
  end

  it "should raise an exception on timeout" do
    @session.timeout = 1
    lambda {@session.get("/timeout")}.should raise_error(Patron::TimeoutError)
  end

end
