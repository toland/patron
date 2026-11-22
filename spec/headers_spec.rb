# frozen_string_literal: true

require File.dirname(__FILE__) + '/spec_helper'

describe Patron::Headers do
  let(:headers) { Patron::ResponseHead.headers_from_lines(["Content-Length: 42", "X-Lowercase: yes"]) }

  it "is a Hash, and equal to one with the same pairs" do
    expect(headers).to be_a(Hash)
    expect(headers).to eq({"Content-Length" => "42", "X-Lowercase" => "yes"})
    expect(headers.to_h).to be_instance_of(Hash)
  end

  it "keeps the keys the way they arrived" do
    expect(headers.keys).to eq(["Content-Length", "X-Lowercase"])
    expect(headers.inspect).to include("Content-Length")
  end

  it "reads a value under any casing of the name" do
    %w[Content-Length content-length CONTENT-LENGTH cOnTeNt-LeNgTh].each do |name|
      expect(headers[name]).to eq("42")
      expect(headers.fetch(name)).to eq("42")
      expect(headers.dig(name)).to eq("42")
      expect(headers.values_at(name)).to eq(["42"])
      expect(headers.assoc(name)).to eq(["Content-Length", "42"])
      expect(headers.slice(name)).to eq({"Content-Length" => "42"})
      expect(headers.except(name)).to eq({"X-Lowercase" => "yes"})
      expect(headers).to have_key(name)
      expect(headers.include?(name)).to be(true)
      expect(headers.member?(name)).to be(true)
    end
  end

  it "still misses a header that is not there" do
    expect(headers["X-Nope"]).to be_nil
    expect(headers).not_to have_key("x-nope")
    expect(headers.fetch("x-nope", :fallback)).to eq(:fallback)
    expect(headers.fetch("x-nope") { :from_block }).to eq(:from_block)
    expect { headers.fetch("x-nope") }.to raise_error(KeyError)
  end

  it "writes to and deletes the header that is already there, whatever the casing" do
    headers["CONTENT-length"] = "43"
    expect(headers.keys).to eq(["Content-Length", "X-Lowercase"])
    expect(headers["Content-Length"]).to eq("43")

    expect(headers.delete("x-LOWERCASE")).to eq("yes")
    expect(headers.keys).to eq(["Content-Length"])

    headers.store("X-New", "1")
    expect(headers["x-new"]).to eq("1")
  end

  it "takes a non-String key without tripping over it" do
    headers[:symbol] = "1"
    expect(headers[:symbol]).to eq("1")
    expect(headers[42]).to be_nil
  end

  it "collects repeated headers into an Array even when the server mixes the casing" do
    headers = Patron::ResponseHead.headers_from_lines(["Set-Cookie: a=1", "set-cookie: b=2", "SET-COOKIE: c=3"])
    expect(headers.keys).to eq(["Set-Cookie"])
    expect(headers["set-cookie"]).to eq(["a=1", "b=2", "c=3"])
  end

  it "survives freezing, which is what a TransferStats does to it" do
    frozen = Patron::ResponseHead.headers_from_lines(["Content-Length: 42"]).freeze
    expect(frozen["content-length"]).to eq("42")
    expect { frozen["x-new"] = "1" }.to raise_error(FrozenError)
  end
end
