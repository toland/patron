## -------------------------------------------------------------------
##
## Patron HTTP Client: Response class
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

  # Represents the response from the HTTP server.
  class Response
    # @return [String] the original URL used to perform the request (contains the final URL after redirects)
    attr_reader :url

    # @return [Fixnum] the HTTP status code of the final response after all the redirects
    attr_reader :status

    # @return [String] the complete status line (code and message)
    attr_reader :status_line

    # @return [Fixnum] how many redirects were followed when fulfilling this request
    attr_reader :redirect_count

    # @return [String, nil] the response body, or nil if the response was written directly to a file
    attr_reader :body

    # @return [Hash] the response headers. If there were multiple headers received for the same value
    #   (like "Cookie"), the header values will be within an Array under the key for the header, in order.
    attr_reader :headers

    # @return [String] the recognized name of the charset for the response
    attr_reader :charset

    # Overridden so that the output is shorter and there is no response body printed
    def inspect
      # Avoid spamming the console with the header and body data
      "#<Patron::Response @status_line='#{@status_line}'>"
    end

    def initialize(url, status, redirect_count, header_data, body, default_charset = nil)
      # Don't let a response clear out the default charset, which would cause encoding to fail
      default_charset = "ASCII-8BIT" unless default_charset
      @url            = url
      @status         = status
      @redirect_count = redirect_count
      @body           = body

      @charset        = determine_charset(header_data, body) || default_charset

      [url, header_data].each do |attr|
        convert_to_default_encoding!(attr)
      end

      parse_headers(header_data)
      if @headers["Content-Type"] && @headers["Content-Type"][0, 5] == "text/"
        convert_to_default_encoding!(@body)
      end
    end

    private

    def determine_charset(header_data, body)
      header_data.match(charset_regex) || (body && body.match(charset_regex))

      charset = $1
      validate_charset(charset) ? charset : nil
    end

    def charset_regex
      /(?:charset|encoding)="?([a-z0-9-]+)"?/i
    end

    def validate_charset(charset)
      charset && Encoding.find(charset) && true
    rescue ArgumentError
      false
    end

    def convert_to_default_encoding!(str)
      if str.respond_to?(:encode) && Encoding.default_internal
        str.force_encoding(charset).encode!(Encoding.default_internal)
      end
    end

    # Called by the C code to parse and set the headers
    def parse_headers(header_data)
      @headers = {}

      lines = header_data.split("\r\n")

      @status_line = lines.shift

      lines.each do |line|
        break if line.empty?

        hdr, val = line.split(":", 2)

        val.strip! unless val.nil?

        if @headers.key?(hdr)
          @headers[hdr] = [@headers[hdr]] unless @headers[hdr].kind_of? Array
          @headers[hdr] << val
        else
          @headers[hdr] = val
        end
      end
    end

  end
end
