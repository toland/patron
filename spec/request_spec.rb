require File.dirname(__FILE__) + '/spec_helper.rb'


describe Patron::Request do

  before(:each) do
    @request = Patron::Request.new
  end

  describe :action do

    it "should accept :get, :put, :post, :delete and :head" do
      [:get, :put, :post, :delete, :head].each do |action|
        lambda {@request.action = action}.should_not raise_error
      end
    end

    it "should raise an exception when assigned a bad value" do
      lambda {@request.action = :foo}.should raise_error(ArgumentError)
    end

  end

  describe :timeout do

    it "should raise an exception when assigned a negative number" do
      lambda {@request.timeout = -1}.should raise_error(ArgumentError)
    end

    it "should raise an exception when assigned 0" do
      lambda {@request.timeout = -1}.should raise_error(ArgumentError)
    end

  end

  describe :max_redirects do

    it "should raise an error when assigned an integer smaller than -1" do
      lambda {@request.max_redirects = -2}.should raise_error(ArgumentError)
    end

  end

  describe :headers do

    it "should raise an error when assigned something other than a hash" do
      lambda {@request.headers = :foo}.should raise_error(ArgumentError)
    end

  end

end
