# frozen_string_literal: true

module Patron

  # A client for server-sent events (`text/event-stream`), built on Session#stream. Parses the
  # stream by the WHATWG event stream algorithm and reconnects the way an EventSource does:
  # after the retry interval, sending Last-Event-ID.
  #
  # @example
  #   client = Patron::SSEClient.new("https://example.com/stream", headers: { "Authorization" => "Bearer ..." }, idle_timeout: 45)
  #   client.each_event do |event|
  #     puts event.type, event.data, event.id
  #     break if event.type == "done"
  #   end
  #   client.last_event_id # to persist between process runs
  #
  # A client holds one stream at a time and is meant for one thread or fiber; only #close may be
  # called from another one.
  class SSEClient
    # One dispatched event. `type` is "message" unless the server sent an `event:` field, `data` is
    # the `data:` lines joined with "\n", `id` the last event ID at the time, or nil.
    Event = Data.define(:type, :data, :id)

    # Raised for a response that is not an event stream: a status other than 200 or 204, or a
    # Content-Type other than text/event-stream. Retrying it is up to the application.
    class UnexpectedResponse < Patron::Error
      # @return [Integer] the HTTP status
      attr_reader :status

      # @return [Hash] the response headers
      attr_reader :headers

      # @return [String] up to the first 4 KB of the response body
      attr_reader :body

      # @param status [Integer]
      # @param headers [Hash]
      # @param body [String]
      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
        super("Expected a text/event-stream with status 200, got status #{status} with Content-Type #{headers.find { |k, _| k.casecmp?("Content-Type") }&.last.inspect}")
      end
    end

    # Raised when the stream could not be reopened within `max_reconnects` attempts
    class ReconnectsExhausted < Patron::Error; end

    BOM = "\xEF\xBB\xBF".b.freeze
    BODY_EXCERPT_SIZE = 4096
    CHUNK_SIZE = 16 * 1024
    LINE_END_RE = /[\r\n]/n
    private_constant :BOM, :BODY_EXCERPT_SIZE, :CHUNK_SIZE, :LINE_END_RE

    # @return [String, nil] the ID of the last event, sent as Last-Event-ID when reconnecting
    attr_reader :last_event_id

    # @param url [String] the stream URL, relative to the Session's base_url if it has one
    # @param headers [Hash] extra request headers
    # @param idle_timeout [Numeric] seconds of silence after which the stream is reopened; becomes
    #   the requests' read_timeout. Servers send comment lines to keep a quiet stream alive.
    # @param retry [Numeric] seconds to wait before reconnecting, until the server sends a `retry:` field
    # @param max_reconnects [Integer, nil] how many times in a row to reconnect without receiving an
    #   event in between, nil for no limit
    # @param last_event_id [String, nil] the ID to resume from
    # @param session [Patron::Session, nil] the Session to use, for TLS, proxy, authentication,
    #   cookies or base_url. Only `timeout` and `read_timeout` are set, per request.
    def initialize(url, headers: {}, idle_timeout: 60, retry: 3, max_reconnects: nil, last_event_id: nil, session: nil)
      @url = url
      @headers = headers
      @idle_timeout = idle_timeout
      @retry_interval = binding.local_variable_get(:retry).to_f # `retry` is a keyword, so no plain local
      @max_reconnects = max_reconnects
      @last_event_id = last_event_id
      @id_buffer = last_event_id
      @session = session || Session.new
      @closed = false
      @wakeup = Thread::Queue.new
    end

    # Opens the stream and yields every event until the block breaks or raises, the server answers
    # 204, or #close is called. Reconnects after a clean end of the stream, an idle timeout,
    # Patron::ConnectionFailed and Patron::PartialFileError.
    #
    # @yieldparam event [Patron::SSEClient::Event]
    # @return [nil]
    # @raise [UnexpectedResponse] for a response that is not an event stream
    # @raise [ReconnectsExhausted] when `max_reconnects` is exceeded
    def each_event(&block)
      raise ArgumentError, "Patron::SSEClient#each_event needs a block" unless block
      @reconnects = 0
      until @closed
        begin
          return if receive_events(&block) == :no_content
        rescue Patron::Aborted
          return if @closed
          raise
        rescue Patron::TimeoutError, Patron::ConnectionFailed, Patron::PartialFileError
          nil
        end
        break if @closed

        @reconnects += 1
        if @max_reconnects && @reconnects > @max_reconnects
          raise ReconnectsExhausted, "Gave up on #{@url} after #{@max_reconnects} reconnects without an event"
        end
        @wakeup.pop(timeout: @retry_interval)
      end
      nil
    end

    # Stops #each_event, which then returns. Safe to call from another thread or fiber. Under a
    # Fiber scheduler a stream waiting for data notices within a second.
    #
    # @return [nil]
    def close
      @closed = true
      @wakeup << :close
      @session.interrupt
      nil
    end

    # @return [Boolean] whether #close has been called
    def closed? = @closed

    private

    def request_headers
      headers = { "Accept" => "text/event-stream", "Cache-Control" => "no-cache" }.merge(@headers)
      headers["Last-Event-ID"] = @last_event_id if @last_event_id
      headers
    end

    def receive_events(&block)
      @session.get_stream(@url, request_headers, timeout: 0, read_timeout: @idle_timeout) do |stream|
        # A #close that came before this request started has been reset along with the transfer
        return if @closed
        return :no_content if stream.status == 204
        unless stream.status == 200 && stream.content_type == "text/event-stream"
          raise UnexpectedResponse.new(stream.status, stream.headers, stream.read(BODY_EXCERPT_SIZE) || +"")
        end
        parse(stream, &block)
      end
      :eof
    end

    def parse(stream, &block)
      buf = String.new(capacity: CHUNK_SIZE, encoding: Encoding::BINARY)
      pending = String.new(encoding: Encoding::BINARY)
      bom_checked = false
      reset_event

      loop do
        begin
          stream.readpartial(CHUNK_SIZE, buf)
        rescue EOFError
          # A "\r" held back for a "\n" that never came does end its line. An event the stream
          # ends in the middle of is not dispatched though
          process_lines(pending << "\n", &block) if pending.end_with?("\r")
          break
        end
        pending << buf

        unless bom_checked
          next if pending.bytesize < BOM.bytesize && BOM.start_with?(pending)
          pending = pending.byteslice(BOM.bytesize, pending.bytesize) if pending.start_with?(BOM)
          bom_checked = true
        end

        pending = process_lines(pending, &block)
      end
    end

    # Takes every complete line off `pending` and returns what is left. A "\r" at the very end may
    # be the first half of a "\r\n" whose "\n" is still on the wire, so it waits for more
    def process_lines(pending, &block)
      pos = 0
      while (line_end = pending.byteindex(LINE_END_RE, pos))
        if pending.getbyte(line_end) == 13 # \r
          break if line_end == pending.bytesize - 1
          terminator = pending.getbyte(line_end + 1) == 10 ? 2 : 1
        else
          terminator = 1
        end
        process_line(pending.byteslice(pos, line_end - pos), &block)
        pos = line_end + terminator
      end
      pos.zero? ? pending : pending.byteslice(pos, pending.bytesize - pos)
    end

    def process_line(line, &block)
      return dispatch(&block) if line.empty?
      return if line.start_with?(":")

      field, value = line.split(":", 2)
      value = value ? value.delete_prefix(" ") : ""
      case field
      when "event" then @event_type = value
      when "data" then (@data ||= []) << value
      when "id" then @id_buffer = (value.empty? ? nil : utf8(value)) unless value.include?("\0")
      when "retry" then @retry_interval = Integer(value, 10) / 1000.0 if value.match?(/\A\d+\z/)
      end
    end

    def dispatch
      @last_event_id = @id_buffer
      if @data
        type = @event_type.nil? || @event_type.empty? ? "message" : utf8(@event_type)
        event = Event.new(type: type, data: utf8(@data.join("\n")), id: @last_event_id)
        reset_event
        @reconnects = 0
        yield event
      else
        reset_event
      end
    end

    def reset_event
      @data = nil
      @event_type = nil
    end

    def utf8(str) = str.dup.force_encoding(Encoding::UTF_8).scrub.freeze
  end
end
