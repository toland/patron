# frozen_string_literal: true

describe Patron::Request, :unit do
  let(:request) { Patron::Request.new }

  describe "action" do
    it "accepts the well-known verbs through the setter and the constructor" do
      [:get, :put, :post, :delete, :head, :copy, "PATCH"].each do |action|
        request.action = action
        expect(request.action).to eq(action.to_s.downcase.to_sym)
        expect(Patron::Request.new(action: action).action).to eq(action.to_s.downcase.to_sym)
      end
    end

    it "accepts any HTTP token as a custom verb" do
      request.action = "PROPFIND"
      expect(request.action_name).to eq("PROPFIND")
    end

    it "raises when assigned something that is not a token" do
      expect { request.action = "not a verb" }.to raise_error(ArgumentError)
    end
  end

  describe "timeout" do
    it "raises when assigned a negative number" do
      expect { request.timeout = -1 }.to raise_error(ArgumentError)
    end

    it "accepts fractional seconds" do
      request.timeout = 0.3
      expect(request.timeout).to eq(0.3)
    end
  end

  describe "max_redirects" do
    it "raises when assigned an integer smaller than -1" do
      expect { request.max_redirects = -2 }.to raise_error(ArgumentError)
    end
  end

  describe "headers" do
    it "raises when assigned something other than a hash" do
      expect { request.headers = :foo }.to raise_error(ArgumentError)
    end
  end

  describe "buffer_size" do
    it "raises when assigned a negative number or zero" do
      expect { request.buffer_size = -1 }.to raise_error(ArgumentError)
      expect { request.buffer_size = 0 }.to raise_error(ArgumentError)
    end
  end

  describe "auth_type" do
    it "maps the symbolic names to the libcurl constants" do
      request.auth_type = :basic
      expect(request.auth_type).to eq(Patron::Request::AuthBasic)
      expect(Patron::Request.new(auth_type: "digest").auth_type).to eq(Patron::Request::AuthDigest)
      expect(Patron::Request.new(auth_type: :any).auth_type).to eq(Patron::Request::AuthAny)
    end

    it "raises for an unknown name" do
      expect { request.auth_type = :ntlm }.to raise_error(ArgumentError)
    end
  end

  describe "upload_data" do
    it "form-encodes a Hash" do
      expect(Patron::Request.new(action: :post, upload_data: { a: 1, b: "x y" }).upload_data).to eq("a=1&b=x%20y")
    end

    it "keeps a Hash as-is for multipart requests, whichever order the attributes come in" do
      expect(Patron::Request.new(upload_data: { a: 1 }, multipart: true, action: :post).upload_data).to eq({ a: 1 })
    end
  end

  it "rejects unknown attributes in the constructor" do
    expect { Patron::Request.new(bogus: 1) }.to raise_error(ArgumentError, /bogus/)
  end

  it "can be reused with only the URL changed" do
    request.url = "http://example.com/a"
    first = request.dup
    request.url = "http://example.com/b"
    expect(first.url).to eq("http://example.com/a")
    expect(request.url).to eq("http://example.com/b")
    expect(request).not_to eql(first)
  end

  it "compares by value" do
    expect(request).to eql(Patron::Request.new)
    expect(request).not_to eql(Patron::Request.new(action: :post))
  end

  it "can be marshaled and unmarshaled" do
    expect(Marshal.load(Marshal.dump(request))).to eql(request)
  end

  it "preserves every attribute when marshaled, including the ones 0.x dropped" do
    request = Patron::Request.new(ssl_cert: "client.pem", ssl_cert_type: "PEM", ssl_key: "client_key.pem",
                                  ssl_key_password: "secret", ssl_version: "TLSv1_2", download_byte_limit: 10)
    restored = Marshal.load(Marshal.dump(request))
    expect(restored.ssl_cert).to eq("client.pem")
    expect(restored.ssl_cert_type).to eq("PEM")
    expect(restored.ssl_key).to eq("client_key.pem")
    expect(restored.ssl_key_password).to eq("secret")
    expect(restored.ssl_version).to eq("TLSv1_2")
    expect(restored.download_byte_limit).to eq(10)
  end
end
