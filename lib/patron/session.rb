## -------------------------------------------------------------------
##
## Patron HTTP Client: Session class
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
require 'patron/error'
require 'patron/request'
require 'patron/response'
require 'patron/session_ext'


module Patron

  # This class represents multiple request/response transactions with an HTTP
  # server. This is the primary API for Patron.
  class Session

    # HTTP connection timeout in milliseconds. Defaults to 1 second (1000 ms).
    attr_accessor :connect_timeout

    # HTTP transaction timeout in seconds. Defaults to 5 seconds.
    attr_accessor :timeout

    # Maximum number of times to follow redirects.
    # Set to 0 to disable and -1 to follow all redirects (the default).
    attr_accessor :max_redirects

    # Prepended to the URL in all requests.
    attr_accessor :base_url

    # Username and password for http authentication
    attr_accessor :username, :password

    # HTTP proxy URL
    attr_accessor :proxy

    # Standard set of headers that are used in all requests.
    attr_reader :headers

    private :ext_initialize, :handle_request

    # Create an instance of the Session class.
    def initialize
      ext_initialize
      @headers = {}
      @timeout = 5
      @connect_timeout = 1000
      @max_redirects = -1
    end

    # Retrieve the contents of the specified +url+ optionally sending the
    # specified headers. If the +base_url+ varaible is set then it is prepended
    # to the +url+ parameter. Any custom headers are merged with the contents
    # of the +headers+ instance variable. The results are returned in a
    # Response object.
    def get(url, options = {})
      do_request(:get, url, options)
    end

    # As #get but sends an HTTP HEAD request.
    def head(url, options = {})
      do_request(:head, url, options)
    end

    def delete(url, options = {})
      do_request(:delete, url, options)
    end

    def put(url, options = {})
      if options[:data].nil? && options[:from_file].nil?
        raise ArgumentError, "Either upload data or a file name must be included"
      end
      do_request(:put, url, options)
    end

    def post(url, options = {})
      if options[:data].nil? && options[:from_file].nil?
        raise ArgumentError, "Either upload data or a file name must be included"
      end
      do_request(:post, url, options)
    end

  private

    # Creates a new Request object from the parameters and instance variables.
    def do_request(action, url, options = {})
      req = Request.new
      req.action = action
      req.timeout = self.timeout
      req.connect_timeout = self.connect_timeout
      req.max_redirects = self.max_redirects
      req.headers = self.headers.merge(options[:headers] || {})
      req.username = self.username
      req.password = self.password
      req.upload_data = options[:data]
      req.upload_file = options[:from_file]
      req.download_file = options[:to_file]
      req.proxy = proxy

      req.url = self.base_url.to_s + url.to_s
      raise ArgumentError, "Empty URL" if req.url.empty?

      handle_request(req)
    end

  end
end
