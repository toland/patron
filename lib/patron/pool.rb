# frozen_string_literal: true

module Patron

  # A pool of Sessions for threads to check out, each with its own warm connections. A Session may
  # move between threads as long as two never use it at once, and that is what the pool guarantees.
  # The members are made lazily by the block, or all at once by #warm_up, which also opens their
  # connections. Thread::Queue underneath, so checking out inside a Fiber scheduler yields to it.
  #
  # @example
  #   PROVIDER = Patron::Pool.new(size: 8) do
  #     Patron::Session.new(base_url: "https://api.provider.com", max_connection_age: 3600, tcp_keepalive: 30)
  #   end.warm_up("/health")
  #
  #   PROVIDER.with { |session| session.get("/accounts/1") }
  class Pool

    # Raised when no Session came free within the pool's timeout
    class Timeout < Patron::Error; end

    # @return [Integer] how many Sessions the pool holds at most
    attr_reader :size

    # @param size [Integer] how many Sessions at most
    # @param timeout [Numeric] seconds a checkout waits for a free Session before raising Pool::Timeout
    # @yieldreturn [Patron::Session] a new member; called at most `size` times
    def initialize(size: 5, timeout: 5, &build)
      raise ArgumentError, "Patron::Pool.new needs a block that builds a Session" unless build
      @size = Integer(size)
      @timeout = timeout
      @build = build
      @available = Thread::Queue.new
      @lock = Mutex.new
      @created = 0
      @idle_since = {}.compare_by_identity
      @shutdown = false
      @keeper = nil
    end

    # Checks a Session out for the block and back in afterwards, whatever happens in between.
    #
    # @yieldparam session [Patron::Session]
    # @return whatever the block returns
    # @raise [Pool::Timeout] when no Session came free in time
    def with
      session = checkout
      begin
        yield session
      ensure
        checkin(session)
      end
    end

    # Takes a Session out of the pool. Prefer #with, which cannot forget to give it back.
    #
    # @return [Patron::Session]
    # @raise [Pool::Timeout] when no Session came free in time
    def checkout
      raise Timeout, "The pool has been shut down" if @shutdown
      session = @available.pop(timeout: 0) || build_member || @available.pop(timeout: @timeout)
      raise Timeout, "The pool has been shut down" if @shutdown
      raise Timeout, "No Session came free in #{@timeout} seconds (#{@size} in the pool)" unless session
      @idle_since.delete(session)
      session
    end

    # Puts a Session back for others to use.
    #
    # @param session [Patron::Session]
    # @return nil
    def checkin(session)
      return nil if @shutdown
      @idle_since[session] = monotonic
      @available.push(session)
      nil
    rescue ClosedQueueError
      nil # shut down between the check and the push
    end

    # Makes every member the pool does not have yet and opens every member's connection with a
    # HEAD to `path` (see Session#warm_up). Members checked out by others at the time are skipped.
    #
    # @param path [String]
    # @return self
    def warm_up(path = "/")
      each_idle_member(force: true) { |session| session.warm_up(path) }
      self
    end

    # Starts a thread that re-warms members that have been sitting idle for `every` seconds, so
    # that a load balancer's idle timeout does not get to them first. One keeper per pool.
    #
    # @param every [Numeric] seconds of idleness after which a member is warmed again
    # @param path [String] what to HEAD
    # @return [Thread] the keeper; `Thread#kill` or #shutdown ends it
    def keep_warm(every: 50, path: "/")
      @keeper&.kill
      @keeper = Thread.new do
        Thread.current.name = "Patron::Pool keep_warm"
        loop do
          sleep every / 2.0
          each_idle_member(idle_for: every) do |session|
            session.warm_up(path)
          rescue Patron::Error
            # A member that cannot reach the server now will try again next round
          end
        end
      end
    end

    # @return [Hash] `:size`, `:created` so far, `:available` right now, and `:waiting` threads
    def stats
      { size: @size, created: @created, available: @available.size, waiting: @available.num_waiting }
    end

    # Ends the keeper thread and drops the members as they are checked in. Checkouts after this
    # raise, and so do the checkouts waiting for a member right now.
    #
    # @return nil
    def shutdown
      @shutdown = true
      @keeper&.kill
      @keeper = nil
      @available.clear
      @available.close
      nil
    end

    private

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # A new member while there is room, else nil
    def build_member
      @lock.synchronize do
        return nil if @created >= @size
        @created += 1
      end
      @build.call
    rescue Exception
      @lock.synchronize { @created -= 1 }
      raise
    end

    # Goes once round the idle members: pops one, yields it, puts it back, until a member comes
    # round for the second time. The pool is never short by more than one member, and the pop never
    # waits, so members in use by others are left alone. A member the block did not get keeps its
    # idle clock. With `force`, the members not made yet are made now.
    def each_idle_member(idle_for: 0, force: false)
      seen = {}.compare_by_identity
      now = monotonic
      while (session = @available.pop(timeout: 0))
        if seen[session]
          requeue(session)
          break
        end
        seen[session] = true
        if force || now - @idle_since.fetch(session, now) >= idle_for
          begin
            yield session
          ensure
            checkin(session)
          end
        else
          requeue(session)
        end
      end
      return unless force
      while (session = build_member)
        begin
          yield session
        ensure
          checkin(session)
        end
      end
    end

    def requeue(session)
      @available.push(session)
    rescue ClosedQueueError
      nil
    end
  end
end
