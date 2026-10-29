# frozen_string_literal: true

# Ruby 4.0 changed the Ractor API (Ractor::Port, #value, #join), and that is the one we target
describe "Patron inside Ractors", :session, :ractors do
  before(:all) { skip "Ractor specs need Ruby 4.0+" unless RUBY_VERSION >= "4" }

  around do |example|
    was = Warning[:experimental]
    Warning[:experimental] = false
    example.run
  ensure
    Warning[:experimental] = was
  end

  let(:base_url) { "http://localhost:#{HTTP_PORT}" }

  it "performs a request from a non-main Ractor and hands the Response back" do
    response = Ractor.new(base_url) do |base_url|
      session = Patron::Session.new(base_url: base_url, headers: { "X-Ractor" => "yes" })
      session.post("/test", { "a" => "1", "b" => "x y" })
    end.value

    expect(response).to be_a(Patron::Response)
    expect(response.status).to eq(200)
    echoed = readback(response.body)
    expect(echoed.request_method).to eq("POST")
    expect(echoed.body).to eq("a=1&b=x%20y")
    expect(echoed.header["x-ractor"]).to eq(["yes"])
    expect(response.headers["Content-Type"]).to eq("application/json")
    expect(response.timings).to include(:total)
    expect(response.decoded_body).to eq(response.body)
  end

  it "returns a shareable Response without copying it, and it still decodes" do
    response = Ractor.new(base_url) do |base_url|
      Ractor.make_shareable(Patron::Session.new(base_url: base_url).get("/test"))
    end.value

    expect(Ractor.shareable?(response)).to be(true)
    expect(response).to be_frozen
    expect(response.decoded_body).to eq(response.body)
    expect(response.inspectable_body).to eq(response.body)
    expect(response.body_decodable?).to be(true)
  end

  it "propagates a Patron::Error with its curl code" do
    ractor = Ractor.new { Patron::Session.new(timeout: 2).get("http://127.0.0.1:1/") }
    expect { ractor.value }.to raise_error(Ractor::RemoteError) do |error|
      expect(error.cause).to be_a(Patron::ConnectionFailed)
      expect(error.cause.curl_code).to eq(7)
    end
  end

  it "runs the progress callback and honours an abort from it" do
    aborted = Ractor.new(base_url) do |base_url|
      session = Patron::Session.new(base_url: base_url, progress_callback: ->(*) { false })
      session.get("/test")
      :not_aborted
    rescue Patron::Aborted
      :aborted
    end.value
    expect(aborted).to eq(:aborted)
  end

  it "downloads to a file and keeps cookies from inside a Ractor" do
    sizes = Ractor.new(base_url) do |base_url|
      require "tempfile"
      Tempfile.create("patron-ractor") do |file|
        session = Patron::Session.new(base_url: base_url)
        session.handle_cookies
        session.get("/setcookie")
        session.get_file("/test", file.path)
        [File.size(file.path), session.get("/test").body]
      end
    end.value
    expect(sizes[0]).to be > 0
    expect(readback(sizes[1]).header["cookie"]).to eq(["session_id=foo123"])
  end

  it "keeps the deprecated 0.x forms working, warning once per Ractor" do
    warnings = Ractor.new(base_url) do |base_url|
      require "stringio"
      $stderr = StringIO.new # ractor-local, so this does not touch the real stderr
      2.times { Patron::Session.new({ base_url: base_url }).get("/test") }
      Patron::Response.new("http://x", 200, 0, "HTTP/1.1 200 OK\r\n\r\n", "hi")
      $stderr.string.lines
    end.value
    expect(warnings.size).to eq(2)
    expect(warnings[0]).to include("Patron::Session.new with a Hash")
    expect(warnings[1]).to include("Patron::Response.new with positional arguments")
  end

  it "refuses to copy, move or share a Session, since it belongs to the Ractor that made it" do
    session = Patron::Session.new(base_url: base_url)
    expect { Ractor.new(session) { |s| s } }.to raise_error(Ractor::Error, /can not copy (a )?Patron::Session/)

    receiver = Ractor.new { Ractor.receive }
    expect { receiver.send(session, move: true) }.to raise_error(Ractor::Error, /can not move (a )?Patron::Session/)

    expect { Ractor.make_shareable(session) }.to raise_error(Ractor::Error, /can not make shareable/)
    expect(session.get("/test").status).to eq(200) # and the Session is none the worse for it
  end

  it "shares a frozen Request between Ractors" do
    request = Ractor.make_shareable(Patron::Request.new(action: :get, url: "#{base_url}/test"))
    status = Ractor.new(request) do |request|
      Patron::Session.new.request(request.action, request.url, request.headers).status
    end.value
    expect(status).to eq(200)
  end

  it "serves a pool of worker Ractors, one Session each, in parallel" do
    results = Ractor::Port.new
    workers = 4.times.map do |n|
      Ractor.new(base_url, results, n) do |base_url, results, n|
        session = Patron::Session.new(base_url: base_url)
        while (path = Ractor.receive)
          results << [n, path, session.get(path).status]
        end
      end
    end

    paths = 40.times.map { |i| "/test?i=#{i}" }
    paths.each_with_index { |path, i| workers[i % workers.size].send(path) }
    received = paths.size.times.map { results.receive }
    workers.each { |w| w.send(nil) }
    workers.each(&:join)

    expect(received.map { |(_, path, _)| path }).to match_array(paths)
    expect(received.map(&:last).uniq).to eq([200])
    expect(received.map(&:first).uniq.size).to eq(4)
  end

  it "survives compaction and GC inside a Ractor while a Session is live" do
    statuses = Ractor.new(base_url) do |base_url|
      session = Patron::Session.new(base_url: base_url, progress_callback: ->(*) { true })
      10.times.map do
        GC.start
        GC.compact
        session.get("/test").status
      end
    end.value
    expect(statuses).to eq([200] * 10)
  end
end
