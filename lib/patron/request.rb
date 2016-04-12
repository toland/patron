## -------------------------------------------------------------------
##
## Patron HTTP Client: Request class
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


require 'patron/util'

module Patron

  # Represents the information necessary for an HTTP request.
  # This is basically a data object with validation. Not all fields will be
  # used in every request.
  class Request

    # Contains the valid HTTP verbs that can be used to perform requests
    VALID_ACTIONS = %w[GET PUT POST DELETE HEAD COPY]

    # Initializes a new Request, which defaults to the GET HTTP verb and
    # has it's timeouts set to 0
    def initialize
      @action = :get
      @headers = {}
      @timeout = 0
      @connect_timeout = 0
      @max_redirects = -1
    end

    READER_VARS = [
      :url, :username, :password, :file_name, :proxy, :proxy_type, :insecure,
      :ignore_content_length, :multipart, :action, :timeout, :connect_timeout,
      :max_redirects, :headers, :auth_type, :upload_data, :buffer_size, :cacert,
      :ssl_version, :automatic_content_encoding, :force_ipv4
    ]

    WRITER_VARS = [
      :url, :username, :password, :file_name, :proxy, :proxy_type, :insecure,
      :ignore_content_length, :multipart, :cacert, :ssl_version, :automatic_content_encoding, :force_ipv4
    ]

    attr_reader *READER_VARS
    attr_writer *WRITER_VARS

    # Set the type of authentication to use for this request.
    #
    # @param [String, Symbol]type The type of authentication to use for this request, can be one of
    #   :basic, :digest, or :any
    #
    # @example
    #   sess.username = "foo"
    #   sess.password = "sekrit"
    #   sess.auth_type = :digest
    def auth_type=(type=:basic)
      @auth_type = case type
      when :basic, "basic"
        Request::AuthBasic
      when :digest, "digest"
        Request::AuthDigest
      when :any, "any"
        Request::AuthAny
      else
        raise "#{type.inspect} is an unknown authentication type"
      end
    end

    # Sets the upload data (request body) for the request. If the
    # given argument is a Hash, the contents of the hash will be handled
    # as form fields and will be form-encoded. The somposition of the request
    # body is then going to be handled by Curl.
    #
    # If the given `data` is any other object, it is going to be treated as a stringable
    # request body (JSON or other verbatim type) and will have it's `to_s` method called
    # before sending out the request.
    #
    # @param data[Hash, #to_s] a Hash of form fields to values, or an object that responds to `to_s`
    def upload_data=(data)
      @upload_data = case data
      when Hash
        self.multipart ? data : Util.build_query_string_from_hash(data, action == :post)
      else
        data
      end
    end

    # Sets the HTTP verb for the request
    #
    # @param action[String] the name of the HTTP verb
    def action=(action)
      if !VALID_ACTIONS.include?(action.to_s.upcase)
        raise ArgumentError, "Action must be one of #{VALID_ACTIONS.join(', ')}"
      end
      @action = action.downcase.to_sym
    end

    # Sets the read timeout for the CURL request, in seconds
    #
    # @param new_timeout[Integer] the number of seconds to wait before raising a timeout error
    def timeout=(new_timeout)
      if new_timeout && new_timeout.to_i < 1
        raise ArgumentError, "Timeout must be a positive integer greater than 0"
      end

      @timeout = new_timeout.to_i
    end

    # Sets the connect timeout for the CURL request, in seconds.
    #
    # @param new_timeout[Integer] the number of seconds to wait before raising a timeout error
    def connect_timeout=(new_timeout)
      if new_timeout && new_timeout.to_i < 1
        raise ArgumentError, "Timeout must be a positive integer greater than 0"
      end

      @connect_timeout = new_timeout.to_i
    end
    
    # Sets the maximum number of redirects that are going to be followed.
    #
    # @param new_max_redirects[Integer] The number of redirects to follow, or `-1` for unlimited redirects.
    def max_redirects=(new_max_redirects)
      if new_max_redirects.to_i < -1
        raise ArgumentError, "Max redirects must be a positive integer, 0 or -1"
      end

      @max_redirects = new_max_redirects.to_i
    end

    # Sets the headers for the request. Headers muse be set with the right capitalization.
    # The previously set headers will be replaced.
    #
    # @param new_headers[Hash] the hash of headers to set.
    def headers=(new_headers)
      if !new_headers.kind_of?(Hash)
        raise ArgumentError, "Headers must be a hash"
      end

      @headers = new_headers
    end

    # @todo figure out what this does in Patron - with non-streaming situations etc
    # Sets the receive buffer size. If you use response streaming, this determines the maximum
    # amount of data that will be buffered before yielding it in the response.
    #
    # @param buffer_size[Integer,nil] the desired buffer size, or `nil` to disable buffering
    def buffer_size=(buffer_size)
      if buffer_size != nil && buffer_size.to_i < 1
        raise ArgumentError, "Buffer size must be a positive integer greater than 0 or nil"
      end

      @buffer_size = buffer_size != nil ? buffer_size.to_i : nil
    end

    # Returns the set HTTP authentication string for basic authentication.
    #
    # @return [String, NilClass] the authentication string or nil if no authentication is used
    def credentials
      return nil if username.nil? || password.nil?
      "#{username}:#{password}"
    end

    # Returns the set HTTP verb
    #
    # @return [String] the HTTP verb
    def action_name
      @action.to_s.upcase
    end

    # Tells whether this Request is configured the same as the other request
    # @return [TrueClass, FalseClass]
    def eql?(request)
      return false unless Request === request

      READER_VARS.inject(true) do |memo, name|
        memo && (self.send(name) == request.send(name))
      end
    end

    alias_method :==, :eql?

    # Returns a Marshalable representation of the Request
    # @return [Array]
    def marshal_dump
      [ @url, @username, @password, @file_name, @proxy, @proxy_type, @insecure,
        @ignore_content_length, @multipart, @action, @timeout, @connect_timeout,
        @max_redirects, @headers, @auth_type, @upload_data, @buffer_size, @cacert ]
    end

    # Reinstates instance variables from a marshaled representation
    # @param data[Array]
    # @return [void]
    def marshal_load(data)
      @url, @username, @password, @file_name, @proxy, @proxy_type, @insecure,
      @ignore_content_length, @multipart, @action, @timeout, @connect_timeout,
      @max_redirects, @headers, @auth_type, @upload_data, @buffer_size, @cacert = data
    end

  end
end
