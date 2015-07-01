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

    attr_reader :url, :status, :status_line, :redirect_count, :body, :headers, :charset

    def inspect
      # Avoid spamming the console with the header and body data
      "#<Patron::Response @status_line='#{@status_line}'>"
    end

    def marshal_dump
      [@url, @status, @status_line, @redirect_count, @body, @headers, @charset]
    end

    def marshal_load(data)
      @url, @status, @status_line, @redirect_count, @body, @headers, @charset = data
    end

  private

    def determine_charset(header_data, body)
      header_data.match(charset_regex) || (body && body.match(charset_regex))

      $1
    end

    def charset_regex
      /(?:charset|encoding)="?([a-z0-9-]+)"?/i
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

      lines.each do |header|
        parts = header.split(':', 2)
        unless parts.empty?
          parts[1].strip! unless parts[1].nil?
          if @headers.has_key?(parts[0])
            @headers[parts[0]] = [@headers[parts[0]]] unless @headers[parts[0]].kind_of? Array
            @headers[parts[0]] << parts[1]
          else
            @headers[parts[0]] = parts[1]
          end
        end
      end
    end

  end
end
