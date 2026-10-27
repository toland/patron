# frozen_string_literal: true


describe Patron::Request do
  let(:request) { Patron::Request.new }

  describe "action" do
    it "accepts the well-known verbs" do
      [:get, :put, :post, :delete, :head, :copy, "PATCH"].each do |action|
        expect(Patron::Request.new(action: action).action).to eq(action.to_s.downcase.to_sym)
      end
    end

    it "accepts any HTTP token as a custom verb" do
      expect(Patron::Request.new(action: "PROPFIND").action_name).to eq("PROPFIND")
    end

    it "raises when assigned something that is not a token" do
      expect { Patron::Request.new(action: "not a verb") }.to raise_error(ArgumentError)
    end
  end

  describe "timeout" do
    it "raises when given a negative number" do
      expect { Patron::Request.new(timeout: -1) }.to raise_error(ArgumentError)
    end

    it "accepts fractional seconds" do
      expect(Patron::Request.new(timeout: 0.3).timeout).to eq(0.3)
    end
  end

  describe "max_redirects" do
    it "raises when given an integer smaller than -1" do
      expect { Patron::Request.new(max_redirects: -2) }.to raise_error(ArgumentError)
    end
  end

  describe "headers" do
    it "raises when given something other than a hash" do
      expect { Patron::Request.new(headers: :foo) }.to raise_error(ArgumentError)
    end
  end

  describe "buffer_size" do
    it "raises when given a negative number or zero" do
      expect { Patron::Request.new(buffer_size: -1) }.to raise_error(ArgumentError)
      expect { Patron::Request.new(buffer_size: 0) }.to raise_error(ArgumentError)
    end
  end

  describe "auth_type" do
    it "maps the symbolic names to the libcurl constants" do
      expect(Patron::Request.new(auth_type: :basic).auth_type).to eq(Patron::Request::AuthBasic)
      expect(Patron::Request.new(auth_type: "digest").auth_type).to eq(Patron::Request::AuthDigest)
      expect(Patron::Request.new(auth_type: :any).auth_type).to eq(Patron::Request::AuthAny)
    end

    it "raises for an unknown name" do
      expect { Patron::Request.new(auth_type: :ntlm) }.to raise_error(ArgumentError)
    end
  end

  describe "upload_data" do
    it "form-encodes a Hash" do
      expect(Patron::Request.new(action: :post, upload_data: { a: 1, b: "x y" }).upload_data).to eq("a=1&b=x%20y")
    end

    it "keeps a Hash as-is for multipart requests" do
      expect(Patron::Request.new(action: :post, multipart: true, upload_data: { a: 1 }).upload_data).to eq({ a: 1 })
    end
  end

  it "is immutable" do
    expect(request.frozen?).to be true
    expect(request).not_to respond_to(:url=)
  end

  it "compares by value" do
    expect(request).to eql(Patron::Request.new)
    expect(request).not_to eql(Patron::Request.new(action: :post))
  end

  it "can be marshaled and unmarshaled" do
    expect(Marshal.load(Marshal.dump(request))).to eql(request)
  end

  it "preserves the client certificate settings when marshaled" do
    request = Patron::Request.new(ssl_cert: "client.pem", ssl_cert_type: "PEM", ssl_key: "client_key.pem", ssl_key_password: "secret")
    restored = Marshal.load(Marshal.dump(request))
    expect(restored.ssl_cert).to eq("client.pem")
    expect(restored.ssl_cert_type).to eq("PEM")
    expect(restored.ssl_key).to eq("client_key.pem")
    expect(restored.ssl_key_password).to eq("secret")
  end
end
