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

    VALID_ACTIONS = %w[GET PUT POST DELETE HEAD COPY]

    def initialize
      @action = 'GET'
      @headers = {}
      @timeout = 0
      @connect_timeout = 0
      @max_redirects = -1
    end

    READER_VARS = [
      :url, :username, :password, :file_name, :proxy, :proxy_type, :insecure,
      :ignore_content_length, :multipart, :action, :timeout, :connect_timeout,
      :max_redirects, :headers, :auth_type, :upload_data, :buffer_size, :cacert
    ]

    WRITER_VARS = [
      :url, :username, :password, :file_name, :proxy, :proxy_type, :insecure,
      :ignore_content_length, :multipart, :cacert
    ]

    attr_reader *READER_VARS
    attr_writer *WRITER_VARS

    # Set the type of authentication to use for this request.
    #
    # @param [String, Symbol] type - The type of authentication to use for this request, can be one of
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

    def upload_data=(data)
      @upload_data = case data
      when Hash
        self.multipart ? data : Util.build_query_string_from_hash(data, action == 'POST')
      else
        data
      end
    end

    def action=(new_action)
      action = new_action.to_s.upcase

      if !VALID_ACTIONS.include?(action)
        raise ArgumentError, "Action must be one of #{VALID_ACTIONS.join(', ')}"
      end

      @action = action
    end

    def timeout=(new_timeout)
      if new_timeout && new_timeout.to_i < 1
        raise ArgumentError, "Timeout must be a positive integer greater than 0"
      end

      @timeout = new_timeout.to_i
    end

    def connect_timeout=(new_timeout)
      if new_timeout && new_timeout.to_i < 1
        raise ArgumentError, "Timeout must be a positive integer greater than 0"
      end

      @connect_timeout = new_timeout.to_i
    end

    def max_redirects=(new_max_redirects)
      if new_max_redirects.to_i < -1
        raise ArgumentError, "Max redirects must be a positive integer, 0 or -1"
      end

      @max_redirects = new_max_redirects.to_i
    end

    def headers=(new_headers)
      if !new_headers.kind_of?(Hash)
        raise ArgumentError, "Headers must be a hash"
      end

      @headers = new_headers
    end

    def buffer_size=(buffer_size)
      if buffer_size != nil && buffer_size.to_i < 1
        raise ArgumentError, "Buffer size must be a positive integer greater than 0 or nil"
      end

      @buffer_size = buffer_size != nil ? buffer_size.to_i : nil
    end

    def credentials
      return nil if username.nil? || password.nil?
      "#{username}:#{password}"
    end

    def eql?(request)
      return false unless Request === request

      READER_VARS.inject(true) do |memo, name|
        memo && (self.send(name) == request.send(name))
      end
    end

    alias_method :==, :eql?

    def marshal_dump
      [ @url, @username, @password, @file_name, @proxy, @proxy_type, @insecure,
        @ignore_content_length, @multipart, @action, @timeout, @connect_timeout,
        @max_redirects, @headers, @auth_type, @upload_data, @buffer_size, @cacert ]
    end

    def marshal_load(data)
      @url, @username, @password, @file_name, @proxy, @proxy_type, @insecure,
      @ignore_content_length, @multipart, @action, @timeout, @connect_timeout,
      @max_redirects, @headers, @auth_type, @upload_data, @buffer_size, @cacert = data
    end

  end
end
