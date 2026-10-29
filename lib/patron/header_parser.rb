# frozen_string_literal: true

module Patron
  module HeaderParser
    HTTP_STATUS_LINE_START_RE = /^HTTP\/\d(\.\d)? \d+/
    HEADER_LINE_START_RE = /^[^:]+:/

    # The status line and header lines of one response
    SingleResponseHeaders = Data.define(:status_line, :headers)

    # Splits the raw header data libcurl hands us into one SingleResponseHeaders per response.
    # There is more than one when redirects were followed, or when a proxy added its own
    # "Connection established" response in front of the real one.
    #
    # @param raw_headers [String] CRLF-delimited header lines, responses separated by empty lines
    # @return [Array<SingleResponseHeaders>]
    def self.parse(raw_headers)
      responses = []
      current_headers = nil
      raw_headers.each_line do |line|
        if line.match?(HTTP_STATUS_LINE_START_RE)
          current_headers = []
          responses << SingleResponseHeaders.new(status_line: line.strip, headers: current_headers)
        elsif line.match?(HEADER_LINE_START_RE)
          raise Patron::Error, "Header should follow an HTTP status line" unless current_headers
          current_headers << line.strip
        end
      end
      responses.each { |r| r.headers.freeze }
    end
  end
end
