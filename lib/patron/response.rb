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
    include ResponseDecoding
    
    # @return [String] the original URL used to perform the request (contains the final URL after redirects)
    attr_reader :url

    # @return [Fixnum] the HTTP status code of the final response after all the redirects
    attr_reader :status

    # @return [String] the complete status line (code and message)
    attr_reader :status_line

    # @return [Fixnum] how many redirects were followed when fulfilling this request
    attr_reader :redirect_count

    # @return [String, nil] the response body as a String encoded as `Encoding::BINARY` or
    #           or `nil` if the response was written directly to a file
    attr_reader :body
    
    # @return [Hash] the response headers. If there were multiple headers received for the same value
    #   (like "Cookie"), the header values will be within an Array under the key for the header, in order.
    attr_reader :headers

    # @return [String] the recognized name of the charset for the response. The name is not checked
    #    to be a valid charset name, just stored. To check the charset for validity, use #body_decodable?
    attr_reader :charset

    # Overridden so that the output is shorter and there is no response body printed
    def inspect
      # Avoid spamming the console with the header and body data
      "#<Patron::Response @status_line='#{@status_line}'>"
    end

    def initialize(url, status, redirect_count, raw_header_data, body, default_charset = nil)
      @url            = url.force_encoding(Encoding::ASCII) # the URL is always an ASCII subset, _always_.
      @status         = status
      @redirect_count = redirect_count
      @body           = body.force_encoding(Encoding::BINARY) if body

      header_data = decode_header_data(raw_header_data)
      parse_headers(header_data)
      @charset = charset_from_content_type
    end

    # Tells whether the HTTP response code is less than 400
    #
    # @return [Boolean]
    def ok?
      !error?
    end
    
    # Tells whether the HTTP response code is larger than 399
    #
    # @return [Boolean]
    def error?
      status >= 400
    end
    
    private

    # Returns the response body converted into the Ruby process internal encoding (the one set as `Encoding.default_internal`).
    # As the response gets returned, the response body is not assumed to be in any encoding whatsoever - it will be explicitly
    # set to `Encoding::BINARY` (as if you were reading a file in binary mode).
    #
    # When you call `decoded_body`, the method will
    # look at the `Content-Type` response header, and check if that header specified a charset. If it did, the method will then
    # check whether the specified charset is valid (whether it is possible to find a matching `Encoding` class in the VM).
    # Once that succeeds, the method will check whether the response body _is_ in the encoding that the server said it is.
    #
    # This might not be the case - you can, for instance, easily serve an HTML document with a UTF-8 header (with the header
    # being configured somewhere on the webserver level) and then have the actual HTML document override it with a
    # `meta` element  or `charset` containing an overriding charset. However, parsing the response body is outside of scope for
    # Patron, so if this situation happens (the server sets a charset in the header but this header does not match what the server
    # actually sends in the body) you will get an exception stating this is a problem.
    #
    # The next step is actually converting the body to the internal Ruby encoding. That stage may raise an exception as well, if
    # you are using an internal encoding which can't represent the response body faithfully. For example, if you run Ruby with
    # a CJK internal encoding, and the response you are trying to decode uses Greek characters and is UTF-8, you are going to
    # get an exception since it is impossible to coerce those characters to your internal encoding.
    #
    # @raise {Patron::HeaderCharsetInvalid} when the server supplied a wrong or incorrect charset, {Patron::NonRepresentableBody}
    #    when unable to decode the body into the current process encoding.
    # @return [String, nil]
    def decoded_body
      return unless @body
      @decoded_body ||= decode_body(true)
    end
    
    # Works the same as `decoded_body`, with one substantial difference: characters which can't be represented
    # in your process' default encoding are going to be replaced with question marks. This can be used for raising
    # errors when you receive responses which indicate errors on the server you are calling. For example, if you expect
    # a binary download, and the server sends you an error message and you don't really want to bother figuring out
    # the encoding it has - but you need to append this response to an error log or similar.
    #
    # @see Patron::Response#decoded_body
    # @return [String, nil]
    def inspectable_body
      return unless @body
      @inspectable_body ||= decode_body(false)
    end
    
    # Tells whether the response body can be decoded losslessly into the curren internal encoding
    #
    # @return [Boolean] true if the body is decodable, false if otherwise
    def body_decodable?
      return true if @body.nil?
      return true if decoded_body
    rescue HeaderCharsetInvalid, NonRepresentableBody
      false
    end
    
    private

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
