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

    ###################################################################
    ### Standard HTTP methods
    ###

    # Retrieve the contents of the specified +url+ optionally sending the
    # specified headers. If the +base_url+ varaible is set then it is prepended
    # to the +url+ parameter. Any custom headers are merged with the contents
    # of the +headers+ instance variable. The results are returned in a
    # Response object.
    def get(url, headers = {})
      request(:get, url, headers)
    end

    def get_file(url, filename, headers = {})
      request(:get, url, headers, :file => filename)
    end

    # As #get but sends an HTTP HEAD request.
    def head(url, headers = {})
      request(:head, url, headers)
    end

    def delete(url, headers = {})
      request(:delete, url, headers)
    end

    def put(url, data, headers = {})
      request(:put, url, headers, :data => data)
    end

    def put_file(url, filename, headers = {})
      request(:put, url, headers, :file => filename)
    end

    def post(url, data, headers = {})
      request(:post, url, headers, :data => data)
    end

    def post_file(url, filename, headers = {})
      request(:post, url, headers, :file => filename)
    end

    ###################################################################
    ### WebDAV methods
    ###

    def copy(url, dest, headers = {})
      headers['Destination'] = dest
      request(:copy, url, headers)
    end

    ###################################################################
    ### Basic API methods
    ###

    # Creates a new Request object from the parameters and instance variables.
    def request(action, url, headers, options = {})
      req = Request.new
      req.action = action
      req.timeout = self.timeout
      req.connect_timeout = self.connect_timeout
      req.max_redirects = self.max_redirects
      req.headers = self.headers.merge(headers)
      req.username = self.username
      req.password = self.password
      req.upload_data = options[:data]
      req.file_name = options[:file]
      req.proxy = proxy

      req.url = self.base_url.to_s + url.to_s
      raise ArgumentError, "Empty URL" if req.url.empty?

      handle_request(req)
    end

  end
end
