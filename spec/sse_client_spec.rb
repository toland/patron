# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'async'

describe Patron::SSEClient, :session do
  let(:base_url) { "http://localhost:#{HTTP_PORT}" }
  let(:key) { SecureRandom.hex(8) }

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def connections(key) = JSON.parse(Patron::Session.new(base_url: base_url).get("/sse-log?key=#{key}").body)

  def client(path, **options)
    described_class.new("#{base_url}#{path}", **options)
  end

  it "assembles events, reconnects after the server's retry interval and sends Last-Event-ID" do
    sse = client("/sse-events?key=#{key}", retry: 3, idle_timeout: 5)
    events = []
    times = []
    sse.each_event do |event|
      events << event
      times << monotonic
      break if events.length == 5
    end

    expect(events.map(&:to_h)).to eq([
      { type: "greeting", data: "hello\n world", id: "1" },
      { type: "message", data: "second", id: "2" },
      { type: "message", data: "\nlone cr", id: "3" },
      { type: "message", data: "nul id ignored", id: "3" },
      { type: "message", data: "after reconnect", id: "4" },
    ])
    expect(events.map { |e| e.data.encoding }.uniq).to eq([Encoding::UTF_8])
    expect(sse.last_event_id).to eq("4")
    expect(connections(key)).to eq([{ "last_event_id" => nil }, { "last_event_id" => "3" }])
    # the server asked for 200 ms, which wins over the 3 s given to the client
    expect(times[4] - times[3]).to be_between(0.2, 2.5)
  end

  it "resumes from a given last_event_id" do
    sse = client("/sse-events?key=#{key}", last_event_id: "42")
    sse.each_event { break }
    expect(connections(key)).to eq([{ "last_event_id" => "42" }])
  end

  it "ends each_event on a 204" do
    expect(client("/sse-no-content").each_event { raise "not reached" }).to be_nil
  end

  it "raises UnexpectedResponse with the start of the body for an error status" do
    expect { client("/sse-error").each_event { } }.to raise_error(described_class::UnexpectedResponse) { |e|
      expect(e).to be_a(Patron::Error)
      expect(e.status).to eq(503)
      expect(e.headers["content-type"]).to eq("text/plain")
      expect(e.body).to eq("e" * 4096)
    }
  end

  it "raises UnexpectedResponse for something that is not an event stream" do
    expect { client("/test").each_event { } }.to raise_error(described_class::UnexpectedResponse, /application\/json/)
  end

  it "reconnects when the stream goes silent for longer than idle_timeout", :timing do
    started = monotonic
    events = []
    client("/sse-silent?key=#{key}", idle_timeout: 0.3, retry: 0.05).each_event do |event|
      events << event
      break if events.length == 2
    end
    expect(events.map(&:data)).to eq(["hi 1", "hi 2"])
    expect(monotonic - started).to be < 2
    expect(connections(key)).to eq([{ "last_event_id" => nil }, { "last_event_id" => "silent-1" }])
  end

  it "gives up after max_reconnects attempts without an event" do
    sse = described_class.new("http://127.0.0.1:1/", retry: 0.01, max_reconnects: 2)
    expect { sse.each_event { } }.to raise_error(described_class::ReconnectsExhausted)
  end

  it "returns quietly from each_event when closed from another thread", :timing do
    sse = client("/sse-silent?key=#{key}", idle_timeout: 10)
    received = []
    closer = Thread.new { sleep 0.3; sse.close }
    started = monotonic
    expect(sse.each_event { |event| received << event }).to be_nil
    closer.join
    expect(received.length).to eq(1)
    expect(monotonic - started).to be < 1.5
    expect(sse).to be_closed
  end

  it "returns when closed during the wait before a reconnect" do
    sse = described_class.new("http://127.0.0.1:1/", retry: 10)
    closer = Thread.new { sleep 0.3; sse.close }
    started = monotonic
    sse.each_event { }
    closer.join
    expect(monotonic - started).to be < 2
  end

  it "uses the Session it is given, and sets only per-request timeouts on it" do
    session = Patron::Session.new(base_url: base_url, timeout: 7)
    sse = described_class.new("/sse-events?key=#{key}", session: session)
    sse.each_event { |event| break }
    expect(session.timeout).to eq(7)
    expect(session.read_timeout).to be_nil
    expect(session.get("/test").status).to eq(200)
  end

  it "needs a block" do
    expect { client("/sse-events").each_event }.to raise_error(ArgumentError)
  end

  it "runs under a Fiber scheduler, alongside other fibers, and closes from another fiber", :fibers do
    ticks = 0
    events = []
    Async do |task|
      ticker = task.async { 20.times { ticks += 1; sleep 0.02 } }
      sse = client("/sse-silent?key=#{key}", idle_timeout: 10)
      task.async { sleep 0.3; sse.close }
      sse.each_event { |event| events << event }
      ticker.wait
    end
    expect(events.map(&:data)).to eq(["hi 1"])
    expect(ticks).to eq(20)
  end

  it "ends the stream with InvalidEncoding when an event is not valid UTF-8" do
    sse = client("/sse-invalid-utf8", idle_timeout: 5)
    events = []
    expect { sse.each_event { |event| events << event } }.to raise_error(Patron::SSEClient::InvalidEncoding, /not valid UTF-8/)
    expect(events.map(&:data)).to eq(["fine"])
    expect(events.first.data.encoding).to eq(Encoding::UTF_8)
  end
end
