# frozen_string_literal: true

module Patron

  # The response of Session#stream while its block runs: the complete head, and the verbs that
  # receive the body. Every read drives the transfer itself, in the calling thread or fiber, until
  # some bytes have arrived, so waiting for the network yields to a Fiber scheduler like any other
  # IO, and an exception raised between two reads is plain Ruby.
  #
  # The reading methods follow IO: #read and #readpartial fill a String the caller owns, so that
  # `IO.copy_stream(stream, destination)` runs without allocating per chunk. Once the block has
  # ended, every reading method raises IOError.
  #
  # Under a Fiber scheduler use #each and #each_line with a block: an external Enumerator
  # (`each.next`) runs the reads on a different fiber.
  class ResponseStream
    include ResponseHead

    CHUNK_SIZE = 64 * 1024
    private_constant :CHUNK_SIZE

    # @api private
    # @param source [Patron::Session, Patron::Transfer] what transfer_read and transfer_finish are called on
    def initialize(source, status:, url:, redirect_count:, header_data:, default_charset: nil)
      @source = source
      @status = status
      @url = url
      @redirect_count = redirect_count
      @header_data = header_data
      @default_charset = default_charset
      @closed = false
      @eof = false
      @peeked = nil
      parse_head(header_data, default_charset)
    end

    def inspect
      "#<Patron::ResponseStream @status_line='#{@status_line}'#{' (closed)' if @closed}>"
    end

    # Reads like IO#read. With a length, receives until that many bytes have arrived or the body
    # ends. Without one, receives the rest of the body.
    #
    # @param length [Integer, nil] how many bytes to read, nil for the rest of the body
    # @param outbuf [String, nil] a String to fill in place instead of allocating one
    # @return [String, nil] binary String; with a length, nil at the end of the body; without one, "" there
    # @raise [IOError] when the stream is closed
    def read(length = nil, outbuf = nil)
      ensure_open!
      if length.nil?
        buf = outbuf || String.new(encoding: Encoding::BINARY)
        kept = 0
        while (n = receive(nil, buf, kept))
          kept += n
        end
        return buf
      end

      raise ArgumentError, "negative length #{length} given" if length.negative?
      buf = outbuf || String.new(capacity: length, encoding: Encoding::BINARY)
      if length.zero?
        buf.clear
        return buf
      end

      kept = 0
      while kept < length && (n = receive(length - kept, buf, kept))
        kept += n
      end
      kept.zero? ? nil : buf
    end

    # Reads like IO#readpartial: returns as soon as some bytes have arrived, at most `maxlen`.
    #
    # @param maxlen [Integer] most bytes to return
    # @param outbuf [String, nil] a String to fill in place instead of allocating one
    # @return [String] binary String
    # @raise [EOFError] at the end of the body
    # @raise [IOError] when the stream is closed
    def readpartial(maxlen, outbuf = nil)
      ensure_open!
      raise ArgumentError, "negative length #{maxlen} given" if maxlen.negative?
      buf = outbuf || String.new(capacity: maxlen, encoding: Encoding::BINARY)
      raise EOFError, "end of file reached" unless receive(maxlen, buf, 0)
      buf
    end

    # Yields the body in chunks of whatever size libcurl delivers them, each a new binary String,
    # so collecting them is safe.
    #
    # @yieldparam chunk [String]
    # @return [self, Enumerator] self, or an Enumerator without a block
    # @raise [IOError] when the stream is closed
    def each
      return enum_for(:each) unless block_given?
      ensure_open!
      loop do
        chunk = String.new(encoding: Encoding::BINARY)
        break unless receive(CHUNK_SIZE, chunk, 0)
        yield chunk
      end
      self
    end

    # Yields the body line by line, each line with its "\n" and binary. A last line without
    # one is yielded when the body ends.
    #
    # @yieldparam line [String]
    # @return [self, Enumerator] self, or an Enumerator without a block
    # @raise [IOError] when the stream is closed
    def each_line
      return enum_for(:each_line) unless block_given?
      carry = String.new(encoding: Encoding::BINARY)
      each do |chunk|
        carry << chunk
        start = 0
        while (newline = carry.byteindex("\n", start))
          yield carry.byteslice(start, newline + 1 - start)
          start = newline + 1
        end
        carry = carry.byteslice(start, carry.bytesize - start) if start > 0
      end
      yield carry unless carry.empty?
      self
    end

    # Receives the rest of the body and throws it away, so that the connection can be reused.
    # Bounded by the same read_timeout, download_byte_limit and interrupts as any read.
    #
    # @return [Integer] how many bytes were discarded, 0 at the end of the body
    # @raise [IOError] when the stream is closed
    def drain!
      ensure_open!
      scratch = String.new(capacity: CHUNK_SIZE, encoding: Encoding::BINARY)
      discarded = 0
      while (n = receive(CHUNK_SIZE, scratch, 0))
        discarded += n
      end
      discarded
    end

    # Tells whether the body has ended. Like IO#eof?, this waits for the next bytes when none
    # have arrived yet.
    #
    # @return [Boolean]
    # @raise [IOError] when the stream is closed
    def eof?
      ensure_open!
      return true if @eof
      return false if @peeked

      peeked = String.new(encoding: Encoding::BINARY)
      @peeked = peeked if receive(CHUNK_SIZE, peeked, 0)
      @eof
    end
    alias eof eof?

    # Ends the transfer. When the body has not been received to its end, its connection is
    # closed rather than reused. Called by Session#stream when the block ends; idempotent.
    #
    # @return [nil]
    def close
      finish
      nil
    end

    # @return [Boolean] whether the stream has been closed
    def closed? = @closed

    private

    attr_reader :header_data

    def ensure_open!
      raise IOError, "closed stream" if @closed
    end

    # Places up to `maxlen` bytes in `buf` after its first `kept` bytes, returns how many or nil at the end
    def receive(maxlen, buf, kept)
      return receive_peeked(maxlen, buf, kept) if @peeked

      placed = @source.__send__(:transfer_read, maxlen, buf, kept)
      @eof = true if placed.nil?
      placed
    end

    # The bytes #eof? had to read ahead
    def receive_peeked(maxlen, buf, kept)
      piece = @peeked
      if maxlen && piece.bytesize > maxlen
        @peeked = piece.byteslice(maxlen, piece.bytesize - maxlen)
        piece = piece.byteslice(0, maxlen)
      else
        @peeked = nil
      end
      buf.force_encoding(Encoding::BINARY)
      buf.replace(buf.byteslice(0, kept)) if buf.bytesize > kept
      buf << piece
      piece.bytesize
    end

    def finish
      return if @closed
      @closed = true
      @tail = @source.__send__(:transfer_finish)
    end

    def receipt
      downloaded_bytes, uploaded_bytes, timings, complete, trailer_data = @tail
      TransferStats.new(
        url: @url, status: @status, redirect_count: @redirect_count, header_data: @header_data,
        default_charset: @default_charset, downloaded_bytes: downloaded_bytes.to_i,
        uploaded_bytes: uploaded_bytes.to_i, timings: timings || {}, complete: !!complete,
        trailer_data: trailer_data || ""
      )
    end
  end
end
