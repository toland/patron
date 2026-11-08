# frozen_string_literal: true

module Patron

  # A request in flight on a Patron::Multi: what a verb call on the pack returns. You hold it,
  # ask it where it stands, join it, and take the Response out of it. A streamed one (from
  # Multi#stream and friends) runs its block in a fiber of its own while the pack is driven,
  # and has TransferStats instead of a Response once the block has returned.
  #
  # #join follows Thread#join: it returns self when the transfer is done, re-raises the request's
  # error when it failed, and with a limit returns nil when the limit passes first.
  class Transfer

    # @return [Patron::Request] the request this transfer was built from
    attr_reader :request

    # @api private
    def initialize(multi, request, slot, &block)
      @multi = multi
      @request = request
      @slot = slot
      @block = block
      @state = :in_flight
      @error = nil
      @response = nil
      @stats = nil
      @stream = nil
      @fiber = nil
      @finished = false
    end

    # @return [Boolean] whether the body is handed to a block as it arrives rather than buffered
    def streaming? = !@block.nil?

    # @return [Boolean] whether the transfer is over, one way or the other
    def done? = @state != :in_flight

    # @return [Boolean] whether the transfer is over and the Response (or the stats) is there
    def succeeded? = @state == :succeeded

    # @return [Boolean] whether the transfer is over and #error has what went wrong
    def failed? = @state == :failed

    # @return [Exception, nil] what failed the transfer: a Patron::Error from libcurl, or whatever
    #   the stream block raised
    attr_reader :error

    # Drives the pack until this transfer is done, like Thread#join. Other transfers of the pack
    # progress meanwhile, and the stream blocks of the pack run.
    #
    # @param limit [Numeric, nil] seconds to wait at most
    # @return [self, nil] self once done, nil when the limit passed first
    # @raise [Patron::Error] the request's own error when it failed, as Thread#join re-raises
    # @raise [Exception] whatever a stream block of this transfer raised
    def join(limit = nil)
      return nil unless @multi.__send__(:drive_until, limit) { done? }
      raise @error if failed?
      self
    end

    # The Response of a buffered transfer.
    #
    # @return [Patron::Response]
    # @raise [Patron::InFlight] when nobody has joined yet and the transfer is not done
    # @raise [Patron::Error] the request's error when it failed
    # @raise [ArgumentError] on a streamed transfer, which has #stats instead
    def response
      raise ArgumentError, "A streamed transfer has no Response; its receipt is #stats" if streaming?
      settled!
      @response
    end

    # The receipt of a streamed transfer, once its block has returned.
    #
    # @return [Patron::TransferStats]
    # @raise [Patron::InFlight] when nobody has joined yet and the block has not returned
    # @raise [Patron::Error] the request's error when it failed
    # @raise [ArgumentError] on a buffered transfer, which has #response instead
    def stats
      raise ArgumentError, "A buffered transfer has a #response, not stats" unless streaming?
      settled!
      @stats
    end

    # Aborts this transfer alone; it then fails with Patron::Aborted. A no-op once it is done.
    #
    # @return self
    def interrupt
      @multi.__send__(:abort_slot, @slot) unless done?
      self
    end

    def inspect
      kind = streaming? ? "stream" : "request"
      "#<Patron::Transfer #{kind} #{@request.action.to_s.upcase} #{@request.url} #{@state}>"
    end

    private

    def settled!
      raise InFlight, "#{inspect} is still in flight; join it or the pack first" unless done?
      raise @error if failed?
    end

    def session_send(*args) = @multi.__send__(:session).__send__(*args)

    # Called by the Multi when multi_drive reports this slot
    def advance
      streaming? ? advance_stream : collect_buffered
    end

    def collect_buffered
      @response = session_send(:multi_collect, @slot)
      settle(:succeeded)
    rescue Patron::Error => e
      settle(:failed, e)
    rescue Exception => e
      # A progress callback that raised: the transfer is over, and the exception is not a
      # request failure to be read later but something that has to come out now
      settle(:failed, e)
      raise
    end

    # The block runs in a plain Fiber: it yields back to the drive loop whenever it asks for bytes
    # that have not arrived, and the loop resumes it once they have. The fiber is a blocking one so
    # that IO the block does on its own blocks the thread rather than calling a Fiber scheduler from
    # a fiber the scheduler did not create.
    def advance_stream
      unless @fiber
        status, url, redirect_count, header_data = session_send(:multi_head, @slot)
        @stream = ResponseStream.new(self, status: status, url: url, redirect_count: redirect_count,
                                     header_data: header_data,
                                     default_charset: @multi.__send__(:session).default_response_charset)
        block = @block
        stream = @stream
        @fiber = Fiber.new(blocking: true) { block.call(stream); nil }
      end
      @multi.__send__(:running, self) { @fiber.resume }
      return if @fiber.alive?

      finish_stream
      settle(:succeeded)
    rescue Patron::Error => e
      finish_stream
      settle(:failed, e)
    rescue Exception => e
      # Out of the block, or a Timeout/Thread#raise that landed while the block ran: the
      # transfer is over with it, and it also comes out of the join that was driving
      finish_stream
      settle(:failed, e)
      raise
    end

    def finish_stream
      return if @finished
      @finished = true
      if @stream
        @stream.close
        @stats = @stream.__send__(:receipt)
      else
        session_send(:multi_collect, @slot)
      end
    end

    def settle(state, error = nil)
      @state = state
      @error = error
      @multi.__send__(:settled, self)
    end

    # The pack is being closed with this transfer still running: unwind its block so that
    # ensure clauses run, then record the abort. A `stream.close` in one of those clauses collects
    # the transfer on the C side; otherwise multi_close drops it right after
    def abandon
      @finished = true
      error = Patron::Aborted.new("The pack was closed")
      if @fiber&.alive?
        begin
          @fiber.raise(error)
        rescue Exception => unwound
          # Our own Aborted coming back out means the block unwound cleanly; anything else
          # is what one of its ensure clauses raised, and that is what the transfer failed with
          error = unwound unless unwound.equal?(error)
        end
      end
      @stream&.instance_variable_set(:@closed, true)
      settle(:failed, error) unless done?
    end

    # ResponseStream reads through these, as it does through Session's transfer_read and
    # transfer_finish. Called from inside the block's fiber.
    def transfer_read(maxlen, buf, kept)
      loop do
        placed = session_send(:multi_read, @slot, maxlen, buf, kept)
        return placed unless placed == :pending
        Fiber.yield
      end
    end

    def transfer_finish
      return nil if @finished && @stream.nil?
      session_send(:multi_collect, @slot)
    rescue Patron::Error
      # The pack was closed under the block; there is nothing left to finish
      nil
    end
  end
end
