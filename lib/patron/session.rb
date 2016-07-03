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


require 'uri'
require 'patron/error'
require 'patron/request'
require 'patron/response'
require 'patron/session_ext'
require 'patron/util'

module Patron

  # This class represents multiple request/response transactions with an HTTP
  # server. This is the primary API for Patron.
  class Session

    # @return [Integer] HTTP connection timeout in seconds. Defaults to 1 second.
    attr_accessor :connect_timeout

    # @return [Integer] HTTP transaction timeout in seconds. Defaults to 5 seconds.
    attr_accessor :timeout

    # Maximum number of redirects to follow
    # Set to 0 to disable and -1 to follow all redirects. Defaults to 5.
    # @return [Integer]
    attr_accessor :max_redirects

    # @return [String] The URL to prepend to all requests.
    attr_accessor :base_url

    # Username for http authentication
    # @return [String,nil] the HTTP basic auth username
    attr_accessor :username
    
    # Password for http authentication
    # @return [String,nil] the HTTP basic auth password
    attr_accessor :password

    # @return [String] Proxy URL in cURL format ('hostname:8080')
    attr_accessor :proxy

    # @return [Integer] Proxy type (default is HTTP)
    # @see Patron::ProxyType
    attr_accessor :proxy_type

    # @return [Hash] headers used in all requests.
    attr_accessor :headers

    # @return [Symbol] the authentication type for the request (`:basic`, `:digest` or `:token`).
    # @see Patron::Request#auth_type
    attr_accessor :auth_type

    # @return [Boolean] `true` if SSL certificate verification is disabled.
    # Please consider twice before using this option..
    attr_accessor :insecure

    # @return [String] the SSL version for the requests, or nil if all versions are permitted
    # The supported values are nil, "SSLv2", "SSLv3", and "TLSv1".
    attr_accessor :ssl_version

    # @return [String] path to the CA file used for certificate verification, or `nil` if CURL default is used
    attr_accessor :cacert

    # @return [Boolean] whether Content-Range and Content-Length headers should be ignored
    attr_accessor :ignore_content_length

    # @return [Integer, nil]
    # Set the buffer size for this request. This option will
    # only be set if buffer_size is non-nil
    attr_accessor :buffer_size

    # @return [String, nil]
    # Sets the name of the charset to assume for the response. The argument should be a String that
    # is an acceptable argument for `Encoding.find()` in Ruby. The variable will only be used if the
    # response does not specify a charset in it's `Content-Type` header already, if it does that charset
    # will take precedence.
    attr_accessor :default_response_charset
    
    # @return [Boolean] Force curl to use IPv4
    attr_accessor :force_ipv4

    # @return [Boolean] Support automatic Content-Encoding decompression and set liberal Accept-Encoding headers
    attr_accessor :automatic_content_encoding
    
    private :handle_request, :add_cookie_file, :set_debug_file

    # Create a new Session object for performing requests.
    #
    # @param args[Hash] options for the Session (same names as the writable attributes of the Session)
    # @yield self
    def initialize(args = {}, &block)

      # Allows accessors to be set via constructor hash. Ex:  {:base_url => 'www.home.com'}
      args.each do |attribute, value|
        send("#{attribute}=", value)
      end

      # Allows accessors to be set via block.
      if block_given?
        yield self
      end

      @headers ||= {}
      @headers['User-Agent'] ||= Patron.user_agent_string
      @timeout ||= 5
      @connect_timeout ||= 1
      @max_redirects ||= 5
      @auth_type ||= :basic
      @force_ipv4 ||= false
    end

    # Turn on cookie handling for this session, storing them in memory by
    # default or in +file+ if specified. The `file` must be readable and
    # writable. Calling multiple times will add more files.
    #
    # @todo the cookie jar and cookie file path options should be split
    # @param file_path[String] path to an existing cookie jar file, or nil to store cookies in memory
    # @return self
    def handle_cookies(file_path = nil)
      if file_path
        path = Pathname(file_path).expand_path
        
        if !File.exists?(file_path) && !File.writable?(path.dirname)
          raise ArgumentError, "Can't create file #{path} (permission error)"
        elsif File.exists?(file_path) && !File.writable?(file_path)
          raise ArgumentError, "Can't read or write file #{path} (permission error)"
        end
      else
        path = nil
      end
      
      # Apparently calling this with an empty string sets the cookie file,
      # but calling it with a path to a writable file sets that file to be
      # the cookie jar (new cookies are written there)
      add_cookie_file(path.to_s)
      
      self
    end

    # Enable debug output to stderr or to specified `file`.
    #
    # @todo Change to an assignment of an IO object
    # @param file[String, nil] path to the file to write debug data to, or `nil` to print to `STDERR`
    # @return self
    def enable_debug(file = nil)
      set_debug_file(file.to_s)
      self
    end

    # Retrieve the contents of the specified `url` optionally sending the
    # specified headers. If the +base_url+ varaible is set then it is prepended
    # to the +url+ parameter. Any custom headers are merged with the contents
    # of the +headers+ instance variable. The results are returned in a
    # Response object.
    # Notice: this method doesn't accept any `data` argument: if you need to send a request body
    # with a GET request, when using ElasticSearch for example, please, use the #request method.
    #
    # @param url[String] the URL to fetch
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def get(url, headers = {})
      request(:get, url, headers)
    end

    # Retrieve the contents of the specified +url+ as with #get, but the
    # content at the URL is downloaded directly into the specified file. The file will be accessed
    # by libCURL bypassing the Ruby runtime entirely.
    #
    # Note that when using this option, the Response object will have ++nil++ as the body, and you
    # will need to read your target file for access to the body string).
    #
    # @param url[String] the URL to fetch
    # @param filename[String] path to the file to save the response body in
    # @return [Patron::Response]
    def get_file(url, filename, headers = {})
      request(:get, url, headers, :file => filename)
    end

    # Same as #get but performs a HEAD request.
    #
    # @see #get
    # @param url[String] the URL to fetch
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def head(url, headers = {})
      request(:head, url, headers)
    end

    # Same as #get but performs a DELETE request.
    #
    # Notice: this method doesn't accept any `data` argument: if you need to send data with
    # a delete request (as might be needed for ElasticSearch), please, use the #request method.
    #
    # @param url[String] the URL to fetch
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def delete(url, headers = {})
      request(:delete, url, headers)
    end

    # Uploads the passed `data` to the specified `url` using an HTTP PUT. Note that
    # unline ++post++, a Hash is not accepted as the ++data++ argument.
    #
    # @todo inconsistency with "post" - Hash not accepted
    # @param url[String] the URL to fetch
    # @param data[#to_s, #to_path] an object that can be converted to a String
    #   to create the request body, or that responds to #to_path to upload the
    #   entire request body from that file
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def put(url, data, headers = {})
      request(:put, url, headers, :data => data)
    end

    # Uploads the passed `data` to the specified `url` using an HTTP PATCH. Note that
    # unline ++post++, a Hash is not accepted as the ++data++ argument.
    #
    # @todo inconsistency with "post" - Hash not accepted
    # @param url[String] the URL to fetch
    # @param data[#to_s, #to_path] an object that can be converted to a String
    #   to create the request body, or that responds to #to_path to upload the
    #   entire request body from that file
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def patch(url, data, headers = {})
      request(:patch, url, headers, :data => data)
    end

    # Uploads the contents of `file` to the specified `url` using an HTTP PUT. The file will be
    # sent "as-is" without any multipart encoding.
    #
    # @param url[String] the URL to fetch
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def put_file(url, filename, headers = {})
      request(:put, url, headers, :file => filename)
    end

    # Uploads the passed `data` to the specified `url` using an HTTP POST.
    #
    # @param url[String] the URL to fetch
    # @param data[Hash, #to_s, #to_path] a Hash of form fields/values,
    #   or an object that can be converted to a String
    #   to create the request body, or an object that responds to #to_path to upload the
    #   entire request body from that file
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def post(url, data, headers = {})
      if data.is_a?(Hash)
        data = data.map {|k,v| urlencode(k.to_s) + '=' + urlencode(v.to_s) }.join('&')
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
      end
      request(:post, url, headers, :data => data)
    end

    # Uploads the contents of `file` to the specified `url` using an HTTP POST.
    # The file will be sent "as-is" without any multipart encoding.
    #
    # @param url[String] the URL to fetch
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def post_file(url, filename, headers = {})
      request(:post, url, headers, :file => filename)
    end

    # Uploads the contents of `filename` to the specified `url` using an HTTP POST,
    # in combination with given form fields passed in `data`.
    #
    # @param url[String] the URL to fetch
    # @param data[Hash] hash of the form fields
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def post_multipart(url, data, filename, headers = {})
      request(:post, url, headers, {:data => data, :file => filename, :multipart => true})
    end

    # @!group WebDAV methods
    # Sends a WebDAV COPY request to the specified +url+.
    #
    # @param url[String] the URL to copy
    # @param dest[String] the URL of the COPY destination
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def copy(url, dest, headers = {})
      headers['Destination'] = dest
      request(:copy, url, headers)
    end
    # @!endgroup
    
    # @!group Basic API methods
    # Send an HTTP request to the specified `url`.
    #
    # @param action[#to_s] the HTTP verb
    # @param url[String] the URL for the request
    # @param headers[Hash] headers to send along with the request
    # @param options[Hash] any additonal setters to call on the Request
    # @see Patron::Request
    # @return [Patron::Response]
    def request(action, url, headers, options = {})
      req = build_request(action, url, headers, options)
      handle_request(req)
    end
    
    # Returns the class that will be used to build a Response
    # from a Curl call.
    #
    # Primarily useful if you need a very lightweight Response
    # object that does not have to perform all the parsing of
    # various headers/status codes. The method must return
    # a module that supports the same interface for +new+
    # as ++Patron::Response++
    #
    # @return [#new] Returns any object that responds to `.new` with 6 arguments
    # @see Patron::Response#initialize
    def response_class
      ::Patron::Response
    end
    
    # Builds a request object that can be used by ++handle_request++
    # Note that internally, ++handle_request++ uses instance variables of
    # the Request object, and not it's public methods.
    #
    # @param action[String] the HTTP verb
    # @paran url[#to_s] the addition to the base url component, or a complete URL
    # @paran headers[Hash] a hash of headers, "Accept" will be automatically set to an empty string if not provided
    # @paran options[Hash] any overriding options (will shadow the options from the Session object)
    # @return [Patron::Request] the request that will be passed to ++handle_request++
    def build_request(action, url, headers, options = {})
      # If the Expect header isn't set uploads are really slow
      headers['Expect'] ||= ''

      Request.new.tap do |req|
        req.action                 = action
        req.headers                = self.headers.merge headers
        req.automatic_content_encoding = options.fetch :automatic_content_encoding, self.automatic_content_encoding
        req.timeout                = options.fetch :timeout,               self.timeout
        req.connect_timeout        = options.fetch :connect_timeout,       self.connect_timeout
        req.force_ipv4             = options.fetch :force_ipv4,            self.force_ipv4
        req.max_redirects          = options.fetch :max_redirects,         self.max_redirects
        req.username               = options.fetch :username,              self.username
        req.password               = options.fetch :password,              self.password
        req.proxy                  = options.fetch :proxy,                 self.proxy
        req.proxy_type             = options.fetch :proxy_type,            self.proxy_type
        req.auth_type              = options.fetch :auth_type,             self.auth_type
        req.insecure               = options.fetch :insecure,              self.insecure
        req.ssl_version            = options.fetch :ssl_version,           self.ssl_version
        req.cacert                 = options.fetch :cacert,                self.cacert
        req.ignore_content_length  = options.fetch :ignore_content_length, self.ignore_content_length
        req.buffer_size            = options.fetch :buffer_size,           self.buffer_size
        req.multipart              = options[:multipart]
        req.upload_data            = options[:data]
        req.file_name              = options[:file]

        base_url = self.base_url.to_s
        url = url.to_s
        raise ArgumentError, "Empty URL" if base_url.empty? && url.empty?
        uri = URI.parse(base_url.empty? ? url : File.join(base_url, url))
        query = uri.query.to_s.split('&')
        query += options[:query].is_a?(Hash) ? Util.build_query_pairs_from_hash(options[:query]) : options[:query].to_s.split('&')
        uri.query = query.join('&')
        uri.query = nil if uri.query.empty?
        url = uri.to_s
        req.url = url
      end
    end
    # @!endgroup
  end
end
