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

module Patron

  # Represents the information necessary for an HTTP request.
  # This is basically a data object with validation. Not all fields will be
  # used in every request.
  class Request

    def initialize
      @action = :get
      @headers = {}
      @timeout = 0
      @connect_timeout = 0
      @max_redirects = -1
    end

    attr_accessor :url, :username, :password, :upload_data
    attr_reader :action, :timeout, :connect_timeout, :max_redirects, :headers

    def action=(new_action)
      if ![:get, :put, :post, :delete, :head].include?(new_action)
        raise ArgumentError, "Action must be one of :get, :put, :post, :delete or :head"
      end

      @action = new_action
    end

    def timeout=(new_timeout)
      if new_timeout.to_i < 1
        raise ArgumentError, "Timeout must be a positive integer greater than 0"
      end

      @timeout = new_timeout.to_i
    end

    def connect_timeout=(new_timeout)
      if new_timeout.to_i < 1
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

    def credentials
      return nil if username.nil? || password.nil?
      "#{username}:#{password}"
    end

  end
end
