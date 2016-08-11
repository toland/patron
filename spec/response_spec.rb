# -*- coding: UTF-8 -*-
# Encoding pragma is needed for loading this test properly on Ruby < 2.0

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
  around(:each) do |example|
    previous_internal = Encoding.default_internal
    example.run
    Encoding.default_internal = previous_internal
  end
  
  before(:each) do
    @session = Patron::Session.new
    @session.base_url = "http://localhost:9001"
  end

  it 'recovers the status code' do
    response = @session.get("/repetitiveheader")
    expect(response.status).to be_kind_of(Fixnum)
    expect(response.status).to eq(200)
  end
  
  it 'saves the definitive URL in the url attribute' do
    headers = "HTTP/1.1 200 OK \r\nContent-Type: text/plain\r\n"
    response = Patron::Response.new("http://example.com/url", 200, 0, headers, '', "UTF-8")
    expect(response.url).to eq("http://example.com/url")
  end
  
  it 'parses the status code and supports ok? and error?' do
    headers = "HTTP/1.1 200 OK \r\nContent-Type: text/plain\r\n"
    body = "abc"
    response = Patron::Response.new("url", 200, 0, headers, body, "UTF-8")
    expect(response.status).to eq(200)
    expect(response).to be_ok
    expect(response).not_to be_error
    
    headers = "HTTP/1.1 400 Bad Request \r\nContent-Type: text/plain\r\n"
    body = "abc"
    response = Patron::Response.new("url", 400, 0, headers, body, "UTF-8")
    expect(response.status).to eq(400)
    expect(response).not_to be_ok
    expect(response).to be_error
  end
  
  it "should strip extra spaces from header values" do
    response = @session.get("/test")
    # All digits, no spaces
    expect(response.headers['Content-Length']).to match(/^\d+$/)
  end

  it "should return an array of values when multiple header fields have same name" do
    response = @session.get("/repetitiveheader")
    expect(response.headers['Set-Cookie']).to be == ["a=1","b=2"]
  end
  
  describe '#decoded_body and #inspectable_body' do
    it "should raise with explicitly binary response bodies but allow an inspectable body" do
      Encoding.default_internal = Encoding::UTF_8
      response = @session.get("/picture")
      expect(response.headers['Content-Type']).to be == 'image/png'
      expect(response.body.encoding).to be == Encoding::BINARY
      expect(response).not_to be_body_decodable
      expect {
        response.decoded_body
      }.to raise_error(Patron::NonRepresentableBody)
      
      inspectable = response.inspectable_body
      expect(inspectable.encoding).to eq(Encoding::UTF_8)
      expect(inspectable).to be_valid_encoding
    end
    
    it "should encode body in the internal charset" do
      allow(Encoding).to receive(:default_internal).and_return("UTF-8")

      greek_encoding = Encoding.find("ISO-8859-7")
      utf_encoding = Encoding.find("UTF-8")

      headers = "HTTP/1.1 200 OK \r\nContent-Type: text/css;charset=ISO-8859-7\r\n"
      body = "Ππ".encode(greek_encoding) # Greek alphabet

      response = Patron::Response.new("url", "status", 0, headers, body, nil)

      expect(response).to be_body_decodable
      expect(response.decoded_body.encoding).to eql(utf_encoding)
    end
    
    it "should fallback to default charset when header or body charset is not valid" do
      allow(Encoding).to receive(:default_internal).and_return("UTF-8")

      encoding = Encoding.find("UTF-8")
      headers = "HTTP/1.1 200 OK \r\nContent-Type: text/css; charset=invalid\r\n"
      body = "who knows which encoding this CSS is in?"

      response = Patron::Response.new("url", "status", 0, headers, body, "UTF-8")
      expect(response.charset).to eq('invalid')
      
      expect(response).not_to be_body_decodable
      expect {
        response.decoded_body
      }.to raise_error(Patron::HeaderCharsetInvalid)
    end
  end

  it "decodes a header that contains UTF-8 even though internal encoding is ASCII" do
    Encoding.default_internal = Encoding::ASCII
    encoding = Encoding.find("UTF-8")
    headers = "HTTP/1.1 200 OK \r\nContent-Disposition: attachment,filename=\"žфайлец.txt\"\r\n"
    body = "this is a file with a Russian filename set in content-disposition"

    response = Patron::Response.new("url", "status", 0, headers, body, "UTF-8")
    dispo = response.headers['Content-Disposition']
    expect(dispo.encoding).to eq(Encoding::UTF_8)
  end
  
  it "should be able to serialize and deserialize itself" do
    expect(Marshal.load(Marshal.dump(@request))).to eql(@request)
  end
end
