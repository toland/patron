module Patron::HeaderParser
  CRLF = /#{Regexp.escape("\r\n")}/

  # Returned for each response parsed out
  class SingleResponseHeaders < Struct.new(:status_line, :headers)
  end

  # Parses a string with lines delimited with CRLF into
  # an Array of SingleResponseHeaders objects. libCURL supplies
  # us multiple responses in sequence, so if we encounter multiple redirect
  # or operate through a proxy - that adds ConnectionEstablished status at
  # the beginning of the response - we need to account for parsing
  # multiple response headres and potentially preserving them.
  #
  # @param [String] the string of headers, with responses delimited by empty lines. All lines must end with CRLF
  # @return Array<SingleResponseHeaders>
  def self.parse(headers_from_multiple_responses_in_sequence)
    s = StringScanner.new(headers_from_multiple_responses_in_sequence)
    responses = []
    until s.eos?
      return unless scanned = s.scan_until(CRLF)
      matched_line = scanned[0..-3]
      if matched_line =~ /^HTTP\/\d\.\d \d+/
        responses << SingleResponseHeaders.new(matched_line.strip, [])
      elsif matched_line =~ /^[^:]+\:/
        raise "Header should follow an HTTP status line" unless responses.any?
        responses[-1].headers << matched_line
      end # else it is the end of the headers for the request
    end
    responses
  end
end
