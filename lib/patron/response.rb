
module Patron

  # Represents the response from the HTTP server.
  class Response

    def initialize
      @headers = {}
    end

    attr_reader :url, :status, :status_line, :redirect_count, :body, :headers

    def inspect
      # Avoid spamming the console with the header and body data
      "#<Patron::Response @status_line='#{@status_line}'>"
    end

  private

    # Called by the C code to parse and set the headers
    def parse_headers(header_data)
      header_data.split(/\r\n/).each do |header|
        if header =~ %r|^HTTP/1.[01]|
          @status_line = header.strip
        else
          parts = header.split(':', 2)
          @headers[parts[0]] = parts[1]
        end
      end
    end

  end
end
