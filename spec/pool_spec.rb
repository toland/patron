# frozen_string_literal: true

require 'async'

describe Patron::Pool, :session do
  let(:base_url) { "http://localhost:#{HTTP_PORT}" }

  def build_pool(**options)
    Patron::Pool.new(size: 3, timeout: 1, **options) { Patron::Session.new(base_url: base_url, timeout: 10) }
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  it "needs a block" do
    expect { Patron::Pool.new(size: 2) }.to raise_error(ArgumentError, /block/)
  end

  it "hands out Sessions with `with` and takes them back" do
    pool = build_pool
    seen = []
    3.times { pool.with { |session| seen << session; expect(session.get("/test").status).to eq(200) } }
    expect(seen.uniq.size).to eq(1) # the same member, since it was always free again
    expect(pool.stats).to eq(size: 3, created: 1, available: 1, waiting: 0)
  end

  it "builds members lazily, up to size, and makes threads wait for a free one" do
    pool = build_pool(timeout: 10) # a slow runner can hold the first three members past the one-second default
    results = Queue.new
    threads = 6.times.map do
      Thread.new { pool.with { |session| results << session.get("/timeout?millis=300").status } }
    end
    threads.each(&:join)
    expect(Array.new(6) { results.pop }).to all(eq(200))
    expect(pool.stats[:created]).to eq(3)
    expect(pool.stats[:available]).to eq(3)
  end

  it "raises Pool::Timeout when nobody gives a Session back in time" do
    pool = build_pool
    held = 3.times.map { pool.checkout }
    started = monotonic
    expect { pool.checkout }.to raise_error(Patron::Pool::Timeout, /1 seconds/)
    expect(monotonic - started).to be_within(0.5).of(1)
    expect(Patron::Pool::Timeout.ancestors).to include(Patron::Error)
    held.each { |session| pool.checkin(session) }
    expect(pool.checkout).to be_a(Patron::Session)
  end

  it "gives the Session back when the block raises" do
    pool = build_pool
    expect { pool.with { |_| raise "boom" } }.to raise_error(RuntimeError, "boom")
    expect(pool.stats[:available]).to eq(1)
  end

  it "warms every member up, so that the first request of each reuses a connection" do
    pool = build_pool
    expect(pool.warm_up("/test")).to equal(pool)
    expect(pool.stats).to include(created: 3, available: 3)
    members = 3.times.map { pool.checkout }
    expect(members.map { |session| session.get("/test").connection_reused? }).to all(be(true))
    members.each { |session| pool.checkin(session) }
  end

  it "re-warms members that sat idle for long enough, with keep_warm" do
    pool = build_pool
    pool.warm_up("/test")
    counts = Hash.new(0)
    keeper = pool.keep_warm(every: 0.4, path: "/test")
    expect(keeper).to be_a(Thread)
    sleep 1.5
    # keeper runs every 0.2 s and warms members idle for >= 0.4 s; each warm_up resets the idle clock
    log = StringIO.new
    members = 3.times.map { pool.checkout }
    members.each { |session| session.enable_debug(log); counts[session] = session.get("/test").connection_reused? }
    expect(counts.values).to all(be(true))
    members.each { |session| pool.checkin(session) }
    pool.shutdown
    expect(keeper.join(2)).to equal(keeper)
    expect(keeper.alive?).to be(false)
  end

  it "shuts down: no more checkouts, members dropped as they come back" do
    pool = build_pool
    session = pool.checkout
    pool.shutdown
    expect { pool.checkout }.to raise_error(Patron::Pool::Timeout, /shut down/)
    pool.checkin(session)
    expect(pool.stats[:available]).to eq(0)
  end

  it "does not count a member whose construction failed" do
    attempts = 0
    pool = Patron::Pool.new(size: 1, timeout: 1) do
      attempts += 1
      raise "cannot build" if attempts == 1
      Patron::Session.new(base_url: base_url)
    end
    expect { pool.checkout }.to raise_error(RuntimeError, "cannot build")
    expect(pool.checkout).to be_a(Patron::Session)
    expect(pool.stats[:created]).to eq(1)
  end

  it "checks out inside Async without blocking the other tasks", :fibers do
    pool = Patron::Pool.new(size: 1, timeout: 5) { Patron::Session.new(base_url: base_url, timeout: 10) }
    ticks = 0
    Async do |task|
      ticker = task.async { 20.times { ticks += 1; sleep 0.02 } }
      holder = task.async { pool.with { |s| s.get("/timeout?millis=300") } }
      waiter = task.async { pool.with { |s| s.get("/test").status } }
      expect(waiter.wait).to eq(200)
      holder.wait
      ticker.wait
    end
    expect(ticks).to be >= 10
  end
end
