# frozen_string_literal: true

require 'uri'
require 'patron/error'
require 'patron/request'
require 'patron/response_decoding'
require 'patron/response'
require 'patron/session_ext'
require 'patron/util'
require 'patron/header_parser'
require 'patron/compat'

module Patron

  # This class represents multiple request/response transactions with an HTTP
  # server. This is the primary API for Patron.
  #
  # A Session owns a libcurl multi handle with its connection cache, so requests to the
  # same host reuse connections. A Session performs one request at a time: use one Session
  # per thread (or per fiber). Performing a request while another thread is already
  # performing one on the same Session raises Patron::Error.
  class Session

    # @return [Numeric] HTTP connection timeout in seconds. Defaults to 1 second.
    attr_accessor :connect_timeout

    # @return [Numeric] HTTP transaction timeout in seconds. Defaults to 5 seconds.
    attr_accessor :timeout

    # @return [Integer] DNS cache timeout in seconds. Defaults to 60 seconds. Set to 0 for no cache, or to -1 for indefinite caching.
    attr_accessor :dns_cache_timeout

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

    # @return [Symbol] the authentication type for the request (`:basic`, `:digest` or `:any`).
    # @see Patron::Request#auth_type
    attr_accessor :auth_type

    # @return [Boolean] `true` if SSL certificate verification is disabled.
    # Please consider twice before using this option..
    attr_accessor :insecure

    # @return [String] the SSL version for the requests, or nil if all versions are permitted.
    # The supported values are the keys of Patron::Request::SSL_VERSIONS:
    # "TLSv1", "TLSv1_0", "TLSv1_1", "TLSv1_2" and "TLSv1_3".
    attr_accessor :ssl_version

    # @return [String] the HTTP version for the requests, or "None" if libcurl is to choose permitted versions.
    # The supported values are the keys of Patron::Request::HTTP_VERSIONS: "None", "HTTPv1_0", "HTTPv1_1",
    # "HTTPv2_0", "HTTPv2_TLS", "HTTPv2_PRIOR", "HTTPv3" and (with libcurl 7.88+) "HTTPv3_ONLY".
    attr_accessor :http_version

    # @return [String] path to the CA file used for certificate verification, or `nil` if CURL default is used
    attr_accessor :cacert

    # @return [String] path to the client SSL certificate file, or `nil` if no client certificate is used
    attr_accessor :ssl_cert

    # @return [String] the client SSL certificate file type: "PEM" (the libcurl default), "DER" or "P12" (PKCS#12)
    attr_accessor :ssl_cert_type

    # @return [String] path to the PEM private key for the client SSL certificate, if it is not bundled with
    #   the certificate itself (as it is with PKCS#12)
    attr_accessor :ssl_key

    # @return [String] the password for the client SSL certificate private key
    attr_accessor :ssl_key_password

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

    # @return [Integer, nil] the maximum number of bytes to download. If it is set to nil
    #    (default) no limit will be applied. Exceeding it raises Patron::DownloadLimitExceeded.
    attr_accessor :download_byte_limit

    # @return [Integer, nil] the time in number seconds that the transfer speed should be below the
    #     `low_speed_limit` for the library to consider it too slow and abort.
    # @see low_speed_limit
    attr_accessor :low_speed_time

    # @return [Integer, nil] the average transfer speed in bytes per second that the transfer should be below
    #    during `low_speed_time` seconds for libcurl to consider it to be too slow and abort.
    # @see low_speed_time
    attr_accessor :low_speed_limit

    # @return [#call, nil] callable object that will be called with 4 arguments
    #    during request/response execution - `dltotal`, `dlnow`, `ultotal`, `ulnow`.
    #    All these arguments are in bytes. Returning `false` from the callback aborts the
    #    request with Patron::Aborted.
    attr_accessor :progress_callback

    # Create a new Session object for performing requests.
    #
    # @param options [Hash] the writable attributes of the Session, by name
    # @yield self
    def initialize(**options, &block)
      options.each do |attribute, value|
        public_send("#{attribute}=", value)
      end

      yield self if block_given?

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

        if !File.exist?(file_path) && !File.writable?(path.dirname)
          raise ArgumentError, "Can't create file #{path} (permission error)"
        elsif File.exist?(file_path) && !File.writable?(file_path)
          raise ArgumentError, "Can't read or write file #{path} (permission error)"
        end
      else
        path = nil
      end

      # libcurl reads the cookie file and, when the path is not empty, also writes the jar back to it
      @cookie_file_path = path.to_s
      set_cookie_file(@cookie_file_path)
      self
    end

    # Enable libcurl's verbose output.
    #
    # @param destination [IO, String, nil] an IO to write to, a path to a file to write to, or `nil` for `$stderr`
    # @return self
    def enable_debug(destination = nil)
      @debug_io = case destination
      when nil then $stderr
      when ->(d) { d.respond_to?(:write) } then destination
      else File.open(destination.to_s, 'wb').tap { |f| f.sync = true }
      end
      set_debug_io(@debug_io)
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
      request(:get, url, headers, file: filename)
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
    # @param url[String] the URL to fetch
    # @param data[#to_s, #to_path] an object that can be converted to a String
    #   to create the request body, or that responds to #to_path to upload the
    #   entire request body from that file
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def put(url, data, headers = {})
      request(:put, url, headers, data: data)
    end

    # Uploads the passed `data` to the specified `url` using an HTTP PATCH. Note that
    # unline ++post++, a Hash is not accepted as the ++data++ argument.
    #
    # @param url[String] the URL to fetch
    # @param data[#to_s, #to_path] an object that can be converted to a String
    #   to create the request body, or that responds to #to_path to upload the
    #   entire request body from that file
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def patch(url, data, headers = {})
      request(:patch, url, headers, data: data)
    end

    # Uploads the contents of `file` to the specified `url` using an HTTP PUT. The file will be
    # sent "as-is" without any multipart encoding.
    #
    # @param url[String] the URL to fetch
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def put_file(url, filename, headers = {})
      request(:put, url, headers, file: filename)
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
        data = data.map { |k, v| urlencode(k.to_s) + '=' + urlencode(v.to_s) }.join('&')
        headers = headers.merge('Content-Type' => 'application/x-www-form-urlencoded')
      end
      request(:post, url, headers, data: data)
    end

    # Uploads the contents of `file` to the specified `url` using an HTTP POST.
    # The file will be sent "as-is" without any multipart encoding.
    #
    # @param url[String] the URL to fetch
    # @param filename[String] path to the file to be uploaded
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def post_file(url, filename, headers = {})
      request(:post, url, headers, file: filename)
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
      request(:post, url, headers, data: data, file: filename, multipart: true)
    end

    # @!group WebDAV methods
    # Sends a WebDAV COPY request to the specified +url+.
    #
    # @param url[String] the URL to copy
    # @param dest[String] the URL of the COPY destination
    # @param headers[Hash] the hash of header keys to values
    # @return [Patron::Response]
    def copy(url, dest, headers = {})
      request(:copy, url, headers.merge('Destination' => dest))
    end
    # @!endgroup

    # @!group Basic API methods
    # Send an HTTP request to the specified `url`.
    #
    # @param action[#to_s] the HTTP verb
    # @param url[String] the URL for the request
    # @param headers[Hash] headers to send along with the request
    # @param options[Hash] any additional Request attributes, plus `:data`, `:file`, `:multipart` and `:query`
    # @see Patron::Request
    # @return [Patron::Response]
    def request(action, url, headers = {}, **options)
      handle_request(build_request(action, url, headers, **options))
    end

    # Returns the class that will be used to build a Response
    # from a Curl call.
    #
    # Primarily useful if you need a very lightweight Response
    # object that does not have to perform all the parsing of
    # various headers/status codes. The method must return
    # a class that supports the same keyword arguments for `new`
    # as Patron::Response.
    #
    # @return [#new]
    # @see Patron::Response#initialize
    def response_class
      ::Patron::Response
    end

    # Builds a request object that can be used by ++handle_request++
    #
    # @param action[String] the HTTP verb
    # @param url[#to_s] the addition to the base url component, or a complete URL
    # @param headers[Hash] a hash of headers, "Expect" will be automatically set to an empty string if not provided
    # @param options[Hash] any overriding options (will shadow the options from the Session object)
    # @return [Patron::Request] the request that will be passed to ++handle_request++
    def build_request(action, url, headers = {}, **options)
      # Without an empty Expect header uploads wait for a "100 Continue" that may never come
      headers = { 'Expect' => '' }.merge(self.headers).merge(headers)

      attributes = REQUEST_ATTRIBUTES_FROM_SESSION.to_h { |name| [name, options.fetch(name) { public_send(name) }] }
      Request.new(
        **attributes,
        action: action,
        url: build_url(url, options[:query]),
        headers: headers,
        multipart: options[:multipart],
        upload_data: options[:data],
        file_name: options[:file]
      )
    end
    # @!endgroup

    private

    REQUEST_ATTRIBUTES_FROM_SESSION = %i[
      automatic_content_encoding timeout connect_timeout dns_cache_timeout low_speed_time low_speed_limit
      force_ipv4 max_redirects username password proxy proxy_type auth_type insecure ssl_version http_version
      cacert ssl_cert ssl_cert_type ssl_key ssl_key_password ignore_content_length buffer_size
      download_byte_limit progress_callback
    ].freeze
    private_constant :REQUEST_ATTRIBUTES_FROM_SESSION

    def build_url(url, query)
      base_url = self.base_url.to_s
      url = url.to_s
      raise ArgumentError, "Empty URL" if base_url.empty? && url.empty?

      full_url = if base_url.empty? || url.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
        url
      else
        "#{base_url.delete_suffix('/')}/#{url.delete_prefix('/')}"
      end

      uri = URI.parse(full_url)
      pairs = uri.query.to_s.split('&')
      pairs += query.is_a?(Hash) ? Util.build_query_pairs_from_hash(query) : query.to_s.split('&')
      uri.query = pairs.empty? ? nil : pairs.join('&')
      uri.to_s
    end

    # Called from the C extension after a fork, when the libcurl handles had to be recreated
    def reapply_base_options
      set_cookie_file(@cookie_file_path) if @cookie_file_path
      set_debug_io(@debug_io) if @debug_io
    end
  end
end
