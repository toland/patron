require File.expand_path("./spec") + '/spec_helper.rb'


describe Patron::Request do

  before(:each) do
    @request = Patron::Request.new
  end

  describe :action do

    it "should accept :get, :put, :post, :delete and :head" do
      [:get, :put, :post, :delete, :head, :copy].each do |action|
        expect {@request.action = action}.not_to raise_error
      end
    end

    it "should raise an exception when assigned a bad value" do
      expect {@request.action = :foo}.to raise_error(ArgumentError)
    end

  end

  describe :timeout do

    it "should raise an exception when assigned a negative number" do
      expect {@request.timeout = -1}.to raise_error(ArgumentError)
    end

  end

  describe :max_redirects do

    it "should raise an error when assigned an integer smaller than -1" do
      expect {@request.max_redirects = -2}.to raise_error(ArgumentError)
    end

  end

  describe :headers do

    it "should raise an error when assigned something other than a hash" do
      expect {@request.headers = :foo}.to raise_error(ArgumentError)
    end

  end

  describe :buffer_size do

    it "should raise an exception when assigned a negative number" do
      expect {@request.buffer_size = -1}.to raise_error(ArgumentError)
    end

    it "should raise an exception when assigned 0" do
      expect {@request.buffer_size = 0}.to raise_error(ArgumentError)
    end

  end

  describe :eql? do

    it "should return true when two requests are equal" do
      expect(@request).to eql(Patron::Request.new)
    end

    it "should return false when two requests are not equal" do
      req = Patron::Request.new
      req.action = :post
      expect(@request).not_to eql(req)
    end

  end

  it "should be able to serialize and deserialize itself" do
    expect(Marshal.load(Marshal.dump(@request))).to eql(@request)
  end
end
