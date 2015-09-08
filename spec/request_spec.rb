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

    it "should raise an exception when assigned 0" do
      expect {@request.timeout = 0}.to raise_error(ArgumentError)
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
