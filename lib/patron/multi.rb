# frozen_string_literal: true

require 'patron/verbs'
require 'patron/transfer'

module Patron

  # A pack of requests that go out together on one Session's connection cache, from Session#multi.
  # It has the Session's verb methods, defaults, headers and cookie jar; every verb call starts
  # the request right away and returns the Patron::Transfer for it. Buffered transfers are read
  # with Transfer#response after a join; streamed ones (#stream and friends) run their block as
  # their bytes arrive, each block in a fiber of its own, while the pack is driven.
  #
  # The pack is driven by #join_all, by #each, and by Transfer#join: whichever of them you call,
  # every transfer of the pack progresses and every stream block runs. The Session is busy from
  # the first verb call until all transfers are done or the pack is closed.
  #
  # Enumerable over the transfers in the order they complete.
  class Multi
    include Verbs
    include Enumerable

    # @api private
    def initialize(session, max_connections: nil)
      @session = session
      @max_connections = max_connections
      @transfers = []
      @by_slot = {}
      @completed = []
      @open = false
      @closed = false
      @running = nil
    end

    # Starts a request in the pack. Same arguments as Session#request.
    #
    # @return [Patron::Transfer]
    def request(action, url, headers = {}, **options)
      add(@session.build_request(action, url, headers, **options))
    end

    # Starts a streamed request in the pack. The block receives the Patron::ResponseStream once the
    # head has arrived and runs, in a fiber of its own, while the pack is driven; the transfer is
    # done when the block has returned. Same arguments as Session#stream.
    #
    # @yieldparam stream [Patron::ResponseStream]
    # @return [Patron::Transfer]
    # @raise [ArgumentError] without a block
    def stream(action, url, headers = {}, **options, &block)
      raise ArgumentError, "Patron::Multi#stream needs a block" unless block
      add(@session.build_request(action, url, headers, **options), &block)
    end

    # Starts a Request built elsewhere, with Session#build_request or taken from a finished
    # transfer. With a block, the response is streamed to it as with #stream.
    #
    # @param request [Patron::Request]
    # @return [Patron::Transfer]
    def add(request, &block)
      raise Patron::Error, "This pack has been closed" if @closed
      open!
      slot = @session.__send__(:multi_add, request, !block.nil?)
      transfer = Transfer.new(self, request, slot, &block)
      @transfers << transfer
      @by_slot[slot] = transfer
      transfer
    rescue Exception
      release!
      raise
    end
    alias << add

    # @return [Array<Patron::Transfer>] every transfer, in the order it was added
    def transfers = @transfers.dup

    # @return [Boolean] whether every transfer is done
    def done? = @transfers.all?(&:done?)

    # Drives the pack until every transfer is done. Never raises for a transfer's failure: there
    # is no one error to raise, and raising one would hide the others. Find them with
    # `select(&:failed?)`. An exception a stream block raises does come out of here.
    #
    # @param limit [Numeric, nil] seconds to wait at most
    # @return [self, nil] self once all are done, nil when the limit passed first
    def join_all(limit = nil)
      drive_until(limit) { done? } ? self : nil
    end

    # Yields the transfers in the order they complete, driving the pack between yields. The block
    # runs between libcurl's own iterations, never inside one. Failed transfers are yielded too.
    #
    # @yieldparam transfer [Patron::Transfer]
    # @return [self, Enumerator]
    def each
      return enum_for(:each) unless block_given?
      index = 0
      loop do
        while index < @completed.size
          yield @completed[index]
          index += 1
        end
        break if done?
        drive_once(nil)
      end
      self
    end

    # Aborts every transfer still in flight; each then fails with Patron::Aborted. A join in
    # progress on another fiber of this thread is raised out of with Patron::Aborted as well.
    #
    # @return self
    def interrupt
      @session.interrupt if @open
      self
    end

    # Ends the pack. Transfers still in flight are dropped (their stream blocks unwind with
    # Patron::Aborted), the Session is free again, and no more requests can be added.
    #
    # @return self
    def close
      return self if @closed
      @closed = true
      @transfers.each { |transfer| transfer.__send__(:abandon) unless transfer.done? }
      @session.__send__(:multi_close) if @open
      @open = false
      self
    end

    # @return [Boolean]
    def closed? = @closed

    def inspect
      "#<Patron::Multi #{@transfers.size} transfers, #{@completed.size} done#{' (closed)' if @closed}>"
    end

    private

    attr_reader :session

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def open!
      return if @open
      @session.__send__(:multi_open, @max_connections)
      @open = true
    end

    # The Session is released as soon as nothing is in flight, so that it can serve plain
    # requests between two rounds on the same pack
    def release!
      return unless @open && done?
      @session.__send__(:multi_close)
      @open = false
    end

    def settled(transfer)
      @completed << transfer
      @by_slot.delete_if { |_, t| t.equal?(transfer) }
      release!
    end

    def abort_slot(slot)
      @session.__send__(:multi_abort, slot) if @open
    end

    def running(transfer)
      previous = @running
      @running = transfer
      yield
    ensure
      @running = previous
    end

    def drive_until(limit)
      deadline = limit && monotonic + limit
      loop do
        return true if yield
        return false if deadline && monotonic >= deadline
        drive_once(deadline && deadline - monotonic)
      end
    end

    def drive_once(max_wait)
      if @running
        raise Patron::Error, "Cannot join a pack from inside one of its stream blocks; the block is already being driven"
      end
      return unless @open
      @session.__send__(:multi_drive, max_wait).each do |slot|
        @by_slot[slot]&.__send__(:advance)
      end
    end
  end
end
