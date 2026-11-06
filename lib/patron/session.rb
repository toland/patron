# frozen_string_literal: true

require 'uri'
require 'patron/error'
require 'patron/request'
require 'patron/header_parser'
require 'patron/response_head'
require 'patron/response_decoding'
require 'patron/verbs'
require 'patron/multi'
require 'patron/response'
require 'patron/connection_info'
require 'patron/pool'
require 'patron/response_stream'
require 'patron/transfer_stats'
require 'patron/session_ext'
require 'patron/util'
require 'patron/compat'

module Patron

  # This class represents multiple request/response transactions with an HTTP
  # server. This is the primary API for Patron.
  #
  # A Session owns a libcurl multi handle with its connection cache, so requests to the
  # same host reuse connections. A Session performs one request at a time: use one Session
  # per thread (or per fiber). Performing a request while another thread is already
  # performing one on the same Session raises Patron::Error. A Session belongs to the Ractor
  # that created it and cannot be sent to or shared with another one; Requests and Responses can.
  class Session
    include Verbs

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

    # @return [Numeric, nil] how long to wait for the next piece of the response, in seconds,
    #    counted from the previous one. Unlike #timeout it does not bound the whole transfer,
    #    which makes it the one to use for streams. Defaults to nil, no limit. Exceeding it
    #    raises Patron::TimeoutError.
    # @see Patron::Request#read_timeout=
    attr_accessor :read_timeout

    # @return [Integer, nil] how long a cached connection may sit idle and still be reused, in seconds.
    #   libcurl's default is 118; a pool of warm connections wants something much longer.
    # @see Patron::Request#max_connection_age=
    attr_accessor :max_connection_age

    # @return [Integer, nil] how long a connection may be reused at all, in seconds since it was made
    # @see Patron::Request#max_connection_lifetime=
    attr_accessor :max_connection_lifetime

    # @return [Integer, true, nil] the TCP keepalive probe interval in seconds, true for 60, nil for off
    # @see Patron::Request#tcp_keepalive=
    attr_accessor :tcp_keepalive

    # @return [Hash{String => String}, nil] "host:port" => address entries that bypass DNS
    # @see Patron::Request#resolve=
    attr_accessor :resolve

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

    # Opens the connection ahead of the first real request: resolves the host, connects, and
    # completes the TLS handshake, with a HEAD request whose response is thrown away. The
    # connection then sits in this Session's cache for the next request to reuse. Set
    # `max_connection_age` as well, or libcurl closes it after 118 idle seconds.
    #
    # @param path [String] what to HEAD, relative to `base_url`; the status does not matter
    # @return self
    def warm_up(path = "/")
      head(path)
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

    # Retrieve the contents of the specified +url+ as with #get, but the
    # content at the URL is downloaded directly into the specified file. The body is streamed
    # into the file through one reused buffer, see #stream.
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



    # @!group Streaming
    # Performs a request and yields its response as a ResponseStream as soon as the head of the
    # final response has arrived, before the body. The block receives the body by reading from
    # the stream; nothing is buffered meanwhile, and a consumer that does not read holds the
    # transfer back. When the block ends before the body does (`break`, `return`, an exception)
    # the transfer is aborted and its connection closed; call ResponseStream#drain! first to keep it.
    #
    # The Session is busy for the duration of the block, so another request on it from inside
    # the block raises Patron::Error. #timeout still bounds the whole transfer and is usually
    # wanted at 0 here, with `read_timeout:` bounding the wait for each next piece instead.
    #
    # @example
    #   stats = session.stream(:get, "/events", { "Accept" => "text/event-stream" }, timeout: 0, read_timeout: 30) do |stream|
    #     raise "Unexpected #{stream.status}" unless stream.ok?
    #     stream.each_line { |line| handle(line) }
    #   end
    #   stats.complete? #=> true
    #
    # @param action[#to_s] the HTTP verb
    # @param url[String] the URL for the request
    # @param headers[Hash] headers to send along with the request
    # @param options[Hash] the same options as #request takes
    # @yieldparam stream [Patron::ResponseStream] closed once the block ends
    # @return [Patron::TransferStats] the receipt of the transfer
    # @raise [ArgumentError] without a block
    def stream(action, url, headers = {}, **options, &block)
      raise ArgumentError, "Patron::Session#stream needs a block" unless block
      run_stream(build_request(action, url, headers, **options), &block).__send__(:receipt)
    end

    # @!endgroup

    # @!group Parallel requests
    # Returns a Patron::Multi: a pack of requests that go out together on this Session's connection
    # cache. It has the same verb methods as the Session; each one starts its request right away and
    # returns a Patron::Transfer to join and read the Response from. With a block, yields the pack,
    # waits for all of it with Multi#join_all, closes it, and returns it.
    #
    # @example
    #   multi = session.multi
    #   account = multi.get("/accounts/1")
    #   orders  = multi.get("/accounts/1/orders")
    #   account.join.response.body
    #   orders.join.response.body
    #
    # @param max_connections [Integer, nil] the most connections the pack may open (CURLMOPT_MAX_TOTAL_CONNECTIONS),
    #   nil for libcurl's default. An HTTP/2 server multiplexes the pack over one connection regardless
    # @yieldparam multi [Patron::Multi]
    # @return [Patron::Multi]
    def multi(max_connections: nil)
      pack = Multi.new(self, max_connections: max_connections)
      return pack unless block_given?
      begin
        yield pack
        pack.join_all
      ensure
        pack.close
      end
      pack
    end
    # @!endgroup

    # @!group Basic API methods
    # Send an HTTP request to the specified `url`.
    #
    # @param action[#to_s] the HTTP verb
    # @param url[String] the URL for the request
    # @param headers[Hash] headers to send along with the request
    # @param options[Hash] any additional Request attributes, plus `:data`, `:file`, `:multipart` and `:query`.
    #   `:data` may be a Hash, a String, or an object responding to #to_path or #read (see Request#upload_data=)
    # @see Patron::Request
    # @return [Patron::Response]
    def request(action, url, headers = {}, *positional, **options)
      # The 0.x positional options Hash is tolerated here rather than in a prepended module, since
      # sniffer and friends alias_method-chain this method and a prepend would recurse into the alias
      options = Compat.hash_to_keywords("Patron::Session#request with an options Hash", positional, options)
      if options[:file] && !options[:multipart] && action.to_s.casecmp?("get")
        return download(build_request(action, url, headers, **options.except(:file)), options[:file])
      end
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
    # @param options[Hash] any overriding options (will shadow the options from the Session object).
    #   `:data` may be a Hash, a String, or an object responding to #to_path or #read (see Request#upload_data=)
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
      download_byte_limit progress_callback read_timeout max_connection_age max_connection_lifetime
      tcp_keepalive resolve
    ].freeze
    private_constant :REQUEST_ATTRIBUTES_FROM_SESSION

    # The ensure is what aborts the transfer on break, return, raise, Thread#kill or Task#stop.
    # A transfer_start that raised has cleaned up after itself - and when it raised because
    # a stream is already open in this very fiber, transfer_finish would end that one
    def run_stream(request)
      head = stream = nil
      begin
        head = transfer_start(request)
        status, effective_url, redirect_count, header_data = head
        stream = ResponseStream.new(self, status: status, url: effective_url, redirect_count: redirect_count,
                                    header_data: header_data, default_charset: default_response_charset)
        yield stream
      ensure
        if stream
          stream.__send__(:finish)
        elsif head
          transfer_finish
        end
      end
      stream
    end

    def download(request, path)
      File.open(path, "wb") do |file|
        stream = run_stream(request) { |s| IO.copy_stream(s, file) }
        stats = stream.__send__(:receipt)
        response_class.new(url: stats.url, status: stats.status, redirect_count: stats.redirect_count,
                           header_data: stream.__send__(:header_data), body: nil,
                           default_charset: default_response_charset, timings: stats.timings)
      end
    end

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
