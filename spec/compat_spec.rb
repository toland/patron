# frozen_string_literal: true

require "stringio"

# Deprecated positional forms kept for 1.0, see lib/patron/compat.rb. Goes away with it in 1.1
describe Patron::Compat, :session do
  let(:headers) { "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" }

  before do
    Patron::Compat.instance_variable_set(:@warned, {})
  end

  def capturing_warnings
    messages = []
    original = $stderr
    $stderr = StringIO.new
    yield
    messages = $stderr.string
  ensure
    $stderr = original
    messages
  end

  it "accepts the six positional Response.new arguments and warns once" do
    output = capturing_warnings do
      2.times do
        response = Patron::Response.new("http://example.com/x", 200, 0, headers, "body", "UTF-8")
        expect(response.url).to eq("http://example.com/x")
        expect(response.status).to eq(200)
        expect(response.body).to eq("body")
        expect(response.charset).to eq("UTF-8")
      end
    end
    expect(output.scan("Patron::Response.new with positional arguments").size).to eq(1)
    expect(output).to include("issues/209")
  end

  it "accepts five positional Response.new arguments" do
    response = nil
    capturing_warnings { response = Patron::Response.new("url", 404, 1, headers, nil) }
    expect(response.redirect_count).to eq(1)
    expect(response.body).to be_nil
  end

  it "still takes keywords without warning" do
    output = capturing_warnings do
      Patron::Response.new(url: "u", status: 200, header_data: headers)
    end
    expect(output).to be_empty
  end

  it "accepts a Hash for Session.new and names the caller in the warning" do
    session = nil
    output = capturing_warnings do
      session = Patron::Session.new({ timeout: 7, "base_url" => "http://localhost:#{HTTP_PORT}" })
    end
    expect(output).to include("compat_spec.rb")
    expect(session.timeout).to eq(7)
    expect(session.get("/test").status).to eq(200)
  end

  it "accepts an options Hash as the fourth argument of request, the way sniffer re-calls it" do
    session = Patron::Session.new(base_url: "http://localhost:#{HTTP_PORT}")
    options = { data: "payload" }
    response = nil
    capturing_warnings { response = session.request(:post, "/testpost", {}, options) }
    expect(readback(response.body).body).to eq("payload")
    expect(session.request(:get, "/test", {}, {}).status).to eq(200)
  end

  it "works through an alias_method wrapper like sniffer's" do
    wrapped = Class.new(Patron::Session) do
      def request_with_wrapper(action, url, headers, options = {})
        @wrapped_calls = (@wrapped_calls || 0) + 1
        request_without_wrapper(action, url, headers, options)
      end
      alias_method :request_without_wrapper, :request
      alias_method :request, :request_with_wrapper
      attr_reader :wrapped_calls
    end
    session = wrapped.new(base_url: "http://localhost:#{HTTP_PORT}")
    expect(session.post("/testpost", "x").status).to eq(200)
    expect(session.wrapped_calls).to eq(1)
  end

  it "works with an alias_method chain installed on Session itself, the way sniffer does it" do
    # Reopening Session would leak into the other specs, so the chain is installed in a child
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      Patron::Session.class_eval do
        def request_with_sniffer(action, url, headers, options = {})
          $sniffed = ($sniffed || 0) + 1
          request_without_sniffer(action, url, headers, options)
        end
        alias_method :request_without_sniffer, :request
        alias_method :request, :request_with_sniffer
      end
      session = Patron::Session.new(base_url: "http://localhost:#{HTTP_PORT}")
      status = nil
      capturing_warnings { status = session.post("/testpost", "x").status }
      wr.write("#{status} #{$sniffed}")
      wr.close
      exit!(0)
    end
    wr.close
    Process.wait(pid)
    expect(rd.read).to eq("200 1")
  end

  it "still rejects genuinely wrong arguments" do
    expect { Patron::Session.new(1) }.to raise_error(ArgumentError)
    expect { Patron::Response.new("a", "b", "c", "d", "e", "f", "g") }.to raise_error(ArgumentError)
  end
end
