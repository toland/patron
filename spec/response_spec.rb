## -------------------------------------------------------------------
##
## Copyright (c) 2009 Phillip Toland <phil.toland@gmail.com>
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
require 'webrick'
require 'base64'
require 'fileutils'

describe Patron::Response do
  before(:each) do
    @session = Patron::Session.new
    @session.base_url = "http://localhost:9001"
  end

  it "should strip extra spaces from header values" do
    response = @session.get("/test")
    # All digits, no spaces
    response.headers['Content-Length'].should match(/^\d+$/)
  end

  it "should return an array of values when multiple header fields have same name" do
    response = @session.get("/repetitiveheader")
    response.headers['Set-Cookie'].should == ["a=1","b=2"]
  end

  it "should works with non-text files" do
    response = @session.get("/picture")
    response.headers['Content-Type'].should == 'image/png'
    response.body.encoding.should == Encoding::ASCII_8BIT
  end
  
  it "should not allow a default charset to be nil" do
    Encoding.stub(:default_internal).and_return("UTF-8")
    expect {
      Patron::Response.new("url", "status", 0, "", "", nil)
    }.to_not raise_error
  end
end
