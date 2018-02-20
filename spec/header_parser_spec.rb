require 'spec_helper'

describe Patron::HeaderParser do
  it 'parses a standard header' do
    simple_headers_path = File.dirname(__FILE__) + '/sample_response_headers/headers_wetransfer.txt'
    responses = Patron::HeaderParser.parse(File.read(simple_headers_path))

    expect(responses.length).to eq(1)
    first_response = responses[0]
    expect(first_response.status_line).to eq("HTTP/1.1 200 OK")
    expect(first_response.headers).to be_kind_of(Array)
    expect(first_response.headers[0]).to eq("Date: Mon, 29 Jan 2018 00:09:09 GMT")
    expect(first_response.headers[1]).to eq("Content-Type: text/html; charset=utf-8")
    expect(first_response.headers[2]).to eq("Transfer-Encoding: chunked")
    expect(first_response.headers[3]).to eq("Connection: keep-alive")
  end

  it 'parses a sequence of responses resulting from a redirect' do
    simple_headers_path = File.dirname(__FILE__) + '/sample_response_headers/headers_wetransfer_with_redirect.txt'
    responses = Patron::HeaderParser.parse(File.read(simple_headers_path))

    expect(responses.length).to eq(2)
    first_response = responses[0]

    expect(first_response.status_line).to eq("HTTP/1.1 301 Moved Permanently")
    expect(first_response.headers).to be_kind_of(Array)
    expect(first_response.headers[0]).to eq("Date: Mon, 29 Jan 2018 00:42:27 GMT")
    expect(first_response.headers[2]).to eq("Connection: keep-alive")
    expect(first_response.headers[3]).to eq("Location: https://wetransfer.com/")
    expect(first_response.headers[4]).to be_nil

    second_response = responses[1]
    expect(second_response.status_line).to eq("HTTP/1.1 200 OK")
    expect(second_response.headers).to be_kind_of(Array)
    expect(second_response.headers[0]).to eq("Date: Mon, 29 Jan 2018 00:42:27 GMT")
    expect(second_response.headers[1]).to eq("Content-Type: text/html; charset=utf-8")
    expect(second_response.headers[2]).to eq("Transfer-Encoding: chunked")
  end

  it 'parses response headers that set cookies' do
    simple_headers_path = File.dirname(__FILE__) + '/sample_response_headers/headers_with_set_cookie.txt'
    responses = Patron::HeaderParser.parse(File.read(simple_headers_path))

    expect(responses.length).to eq(1)
    first_response = responses[0]

    expect(first_response.status_line).to eq("HTTP/1.1 200 OK")
    expect(first_response.headers).to be_kind_of(Array)
    expect(first_response.headers[0]).to eq("Content-Type: text/plain")
    expect(first_response.headers[1]).to start_with('Server:')
    expect(first_response.headers[2]).to eq("Date: Mon, 29 Jan 2018 01:50:54 GMT")
    expect(first_response.headers[3]).to eq("Content-Length: 3")
    expect(first_response.headers[4]).to eq("Connection: Keep-Alive")
    expect(first_response.headers[5]).to eq("Set-Cookie: a=1")
  end

  it 'parses response headers with an extra status line from a proxy' do
    simple_headers_path = File.dirname(__FILE__) + '/sample_response_headers/headers_wetransfer_with_proxy_status.txt'
    responses = Patron::HeaderParser.parse(File.read(simple_headers_path))

    expect(responses.length).to eq(2)
    first_response = responses[0]

    expect(first_response.status_line).to eq("HTTP/1.1 200 Connection established")
    expect(first_response.headers).to be_kind_of(Array)
    expect(first_response.headers).to be_empty

    second_response = responses[1]
    expect(second_response.status_line).to eq("HTTP/1.1 200 OK")
    expect(second_response.headers).to be_kind_of(Array)
    expect(second_response.headers[0]).to eq("Date: Mon, 29 Jan 2018 00:09:09 GMT")
  end

  it 'parses headers without the trailing CRLF from Webmock' do
    path = File.dirname(__FILE__) + '/sample_response_headers/webmock_headers_without_trailing_crlf.txt'
    responses = Patron::HeaderParser.parse(File.read(path))

    expect(responses.length).to eq(1)
    first_response = responses[0]

    expect(first_response.status_line).to eq("HTTP/1.1 200 OK")
    expect(first_response.headers).to be_kind_of(Array)
    expect(first_response.headers).not_to be_empty
    last_header = first_response.headers[-1]
    expect(last_header).to eq('Connection: Close')
  end

  it 'parses headers for an HTTP2 response' do
    path = File.dirname(__FILE__) + '/sample_response_headers/sample_http2_header.txt'
    responses = Patron::HeaderParser.parse(File.read(path))

    expect(responses.length).to eq(1)
    first_response = responses[0]

    expect(first_response.status_line).to eq("HTTP/2 200")
    expect(first_response.headers).to be_kind_of(Array)
    expect(first_response.headers).not_to be_empty
    last_header = first_response.headers[-1]
    expect(last_header).to eq('strict-transport-security: max-age=15552000; includeSubDomains;')
  end
end
