# frozen_string_literal: true

require 'json'
require 'zlib'

## HTTP test server for integration tests

# Echoes the request back as JSON so that the specs can assert on what actually arrived.
# Headers come back as name => [values] the way Webrick used to give them, since the
# specs were written against that shape
ReadbackServlet = Proc.new {|env|
  req = Rack::Request.new(env)
  req_headers = env.to_a.select do |(k,v)|
    k.is_a?(String) && v.is_a?(String)
  end.map do |(k,v)|
   [k.downcase.gsub(/^http_/, '').gsub(/_/o, '-'), [v]]
  end

  body_str = JSON.generate({
    'fullpath' => req.fullpath,
    'path' => req.path,
    'query_string' => req.query_string,
    'request_method' => req.request_method.to_s,
    'header' => req_headers.to_h,
    'body_base64' => [env['rack.input'].read].pack('m0'),
  })
  [200, {'Content-Type' => 'application/json', 'Content-Length' => body_str.bytesize.to_s}, [body_str]]
}

DeflateServlet = Proc.new {|env|
  raise "Need to have the right Accept-Encoding: header" unless env['HTTP_ACCEPT_ENCODING']

  body = []
  content_length = 0
  z = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION)
  1024.times do
    chunk = z.deflate('Some highly compressible data')
    content_length += chunk.bytesize
    body << chunk
  end
  fin = z.finish.to_s
  body << fin
  content_length += fin.bytesize
  z.close

  [200, {'Content-Encoding' => 'deflate', 'Content-Length' => content_length.to_s, 'Vary' => 'Accept-Encoding'}, body]
}

TimeoutServlet = Proc.new {|env|
  query_vars = Rack::Utils.parse_nested_query(env.fetch('QUERY_STRING'))
  query_millis = query_vars.fetch('millis').to_i
  sleep(query_millis / 1000.0)
  [200, {'Content-Type' => 'text/plain'}, ['That took a while']]
}

SlowServlet = Proc.new {|env|
  body = Enumerator.new do |y|
    y.yield 'x'
    sleep 5
    y.yield 'rest of body'
  end
  [200, {'Content-Type' => 'text/plain'}, body]
}

RedirectServlet = Proc.new {|env|
  url_scheme = env.fetch('rack.url_scheme')
  port = env.fetch('SERVER_PORT')
  [301, {'Location' => "#{url_scheme}://localhost:#{port}/test"}, []]
}

EvilRedirectServlet = Proc.new {|env|
  [301, {'Location' => "smtp://mailbox:secret@localhost"}, []]
}

BodyReadback = Proc.new {|env|
  body_str = JSON.generate({
    'request_method' => env['REQUEST_METHOD'],
    'body_base64' => [env['rack.input'].read].pack('m0'),
    'content_type' => env.fetch('CONTENT_TYPE'),
  })
  [200, {'Content-Type' => 'application/json'}, [body_str]]
}

SetCookieServlet = Proc.new {|env|
  [301, {'Set-Cookie' => 'session_id=foo123', 'Location' => "#{env.fetch('rack.url_scheme')}://localhost:#{env.fetch('SERVER_PORT')}/test"}, []]
}

RepetitiveHeaderServlet = Proc.new {|env|
  [200, {'Set-Cookie' => ['a=1', 'b=2'], 'Content-Type' => 'text/plain'}, ['Hi.']]
}

PictureServlet = Proc.new {|env|
  # Rack::Files gives us Range support for free
  env_with_adjusted_path = env.merge('PATH_INFO' => '/pic.png')
  status, headers, body = Rack::Files.new(__dir__).call(env_with_adjusted_path)
  # Rack 3 lowercases header names, but the specs look them up the way real servers send them
  [status, headers.transform_keys { |k| k.split('-').map(&:capitalize).join('-') }, body]
}

RedirectToPictureServlet = Proc.new {|env|
  [307, {'Location' => '/picture'}, []]
}

WrongContentLengthServlet = Proc.new {|env|
  [200, {'Content-Length' => '1024', 'Content-Type' => 'text/plain'}, ['Hello.']]
}

# Serves a substantial amount of data
LargeServlet = Proc.new {|env|
  rng = Random.new
  len = 15 * 1024 * 1024
  body = Enumerator.new do |y|
    15.times do
      y.yield(rng.bytes(1024 * 1024))
    end
  end
  [200, {'Content-Type' => 'binary/octet-stream', 'Content-Length' => len.to_s}, body]
}

# Echoes the subject of the client certificate Puma verified, if any
PeerCertServlet = Proc.new {|env|
  subject = env['puma.peercert'] ? env['puma.peercert'].subject.to_s : 'none'
  [200, {'Content-Type' => 'text/plain', 'Content-Length' => subject.bytesize.to_s}, [subject]]
}

run Rack::URLMap.new({
  "/" => Proc.new {|env| [200, {'Content-Length' => '7'}, ['Welcome']]},
  "/test" => ReadbackServlet,
  "/testpost" => BodyReadback,
  "/testpatch" => BodyReadback,
  "/timeout" => TimeoutServlet,
  "/slow" => SlowServlet,
  "/redirect" => RedirectServlet,
  "/evil-redirect" => EvilRedirectServlet,
  "/picture" => PictureServlet,
  "/redirect-to-picture" => RedirectToPictureServlet,
  "/very-large" => LargeServlet,
  "/setcookie" => SetCookieServlet,
  "/repetitiveheader" => RepetitiveHeaderServlet,
  "/wrongcontentlength" => WrongContentLengthServlet,
  "/deflate-compressed" => DeflateServlet,
  "/peercert" => PeerCertServlet,
})
