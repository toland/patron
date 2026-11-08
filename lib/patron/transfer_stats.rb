# frozen_string_literal: true

module Patron

  # The receipt Session#stream returns once its block has ended: the same head readers as
  # the ResponseStream had, plus what is only known once the body is over. Frozen and
  # Ractor-shareable.
  class TransferStats
    include ResponseHead

    # @return [Integer] body bytes received, as libcurl counts them (CURLINFO_SIZE_DOWNLOAD_T)
    attr_reader :downloaded_bytes

    # @return [Integer] request body bytes sent (CURLINFO_SIZE_UPLOAD_T)
    attr_reader :uploaded_bytes

    # @return [Hash{Symbol => Float}] the same transfer marks as Response#timings
    attr_reader :timings

    # @return [Hash] the trailers that followed a chunked or HTTP/2 body, in the same shape as
    #   #headers. Empty when there were none, or when the block left before the end of the body.
    attr_reader :trailers

    # @return [Patron::ConnectionInfo, nil] the connection the response came over
    attr_reader :connection

    # @param url [String] the effective URL after redirects
    # @param status [Integer] the HTTP status code
    # @param redirect_count [Integer] how many redirects were followed
    # @param header_data [String] the raw header lines of every response in the chain
    # @param downloaded_bytes [Integer]
    # @param uploaded_bytes [Integer]
    # @param timings [Hash{Symbol => Float}]
    # @param complete [Boolean] whether the body was received to its end
    # @param trailer_data [String] the raw trailer lines
    # @param default_charset [String, nil] the charset to assume when the Content-Type header names none
    # @param connection [Patron::ConnectionInfo, Hash, nil] see #connection
    def initialize(url:, status:, redirect_count:, header_data:, downloaded_bytes:, uploaded_bytes:, timings:,
                   complete:, trailer_data: "", default_charset: nil, connection: nil)
      @url = url
      @status = status
      @redirect_count = redirect_count
      @downloaded_bytes = downloaded_bytes
      @uploaded_bytes = uploaded_bytes
      @timings = timings
      @complete = complete
      @connection = ConnectionInfo.coerce(connection)
      parse_head(header_data, default_charset)
      @trailers = ResponseHead.headers_from_lines(trailer_lines(trailer_data))
      Ractor.make_shareable(self)
    end

    # @return [Boolean] whether the body was received to its end. False when the block left
    #   early, raised, or the transfer failed.
    def complete? = @complete

    # @return [Boolean, nil] whether the response came over a connection the Session already had open
    def connection_reused? = @connection&.reused?

    def inspect
      "#<Patron::TransferStats @status_line='#{@status_line}' complete=#{@complete} downloaded_bytes=#{@downloaded_bytes}>"
    end

    private

    def trailer_lines(trailer_data)
      decode_header_data(trailer_data).each_line.map(&:strip).select { |line| line.match?(HeaderParser::HEADER_LINE_START_RE) }
    end
  end
end
