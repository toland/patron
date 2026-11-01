# frozen_string_literal: true

module Patron

  # The facts known once the head of a response has arrived: status, headers, the effective
  # URL. Shared by Response, ResponseStream and TransferStats, so that a header value has
  # one shape wherever it is looked at.
  module ResponseHead
    CHARSET_CONTENT_TYPE_RE = /(?:charset|encoding)="?([a-z0-9-]+)"?/i

    # @return [String] the original URL used to perform the request (contains the final URL after redirects)
    attr_reader :url

    # @return [Integer] the HTTP status code of the final response after all the redirects
    attr_reader :status

    # @return [String] the complete status line (code and message)
    attr_reader :status_line

    # @return [Integer] how many redirects were followed when fulfilling this request
    attr_reader :redirect_count

    # @return [Hash] the response headers. If there were multiple headers received for the same value
    #   (like "Cookie"), the header values will be within an Array under the key for the header, in order.
    attr_reader :headers

    # @return [String] the recognized name of the charset for the response. The name is not checked
    #    to be a valid charset name, just stored.
    attr_reader :charset

    # Tells whether the HTTP response code is less than 400
    #
    # @return [Boolean]
    def ok? = !error?

    # Tells whether the HTTP response code is larger than 399
    #
    # @return [Boolean]
    def error? = status >= 400

    # @return [Integer, nil] the Content-Length header as an Integer, nil when absent or not a number
    def content_length
      value = header_value("Content-Length")
      value = value.first if value.is_a?(Array)
      value.to_s.match?(/\A\d+\z/) ? Integer(value, 10) : nil
    end

    # @return [String, nil] the media type from the Content-Type header, without its parameters
    #   and in lowercase, e.g. "text/event-stream"
    def content_type
      value = content_type_header
      value = value.first if value.is_a?(Array)
      media_type = value.to_s.split(";", 2).first.to_s.strip.downcase
      media_type.empty? ? nil : media_type
    end

    # Builds a header Hash from "Name: value" lines, with repeated names collected into an Array
    #
    # @api private
    # @param lines [Array<String>]
    # @return [Hash]
    def self.headers_from_lines(lines)
      lines.each_with_object({}) do |line, headers|
        hdr, val = line.split(":", 2)
        val = val&.strip

        if headers.key?(hdr)
          headers[hdr] = [headers[hdr]] unless headers[hdr].kind_of?(Array)
          headers[hdr] << val
        else
          headers[hdr] = val
        end
      end
    end

    private

    def parse_head(header_data, default_charset)
      responses = Patron::HeaderParser.parse(decode_header_data(header_data))
      last_response = responses[-1] # proxies and redirects put their own responses in front of the real one

      @status_line = last_response&.status_line
      @headers = ResponseHead.headers_from_lines(last_response ? last_response.headers : [])
      @charset = charset_from_content_type || default_charset
    end

    def charset_from_content_type
      content_type_header.to_s[CHARSET_CONTENT_TYPE_RE, 1]
    end

    # HTTP/2 servers and Puma 8+ send header names lowercase, and `@headers` keeps them as received
    def content_type_header = header_value("Content-Type")

    def header_value(name)
      @headers.find { |hdr, _| hdr.casecmp?(name) }&.last
    end

    def decode_header_data(str)
      # Headers are ISO-8859-1 by the book, but Content-Disposition routinely arrives as raw UTF-8
      # and every browser but localized IE treats it as such, so 8859-1 -> UTF-8 -> binary it is
      [Encoding::ISO8859_1, Encoding::UTF_8, Encoding::BINARY].each do |possible_enc|
        return str.encode(possible_enc)
      rescue ::Encoding::UndefinedConversionError
        next
      end
      str
    end
  end
end
