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
  [200, {'content-type' => 'application/json', 'content-length' => body_str.bytesize.to_s}, [body_str]]
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

  [200, {'content-encoding' => 'deflate', 'content-length' => content_length.to_s, 'vary' => 'Accept-Encoding'}, body]
}

TimeoutServlet = Proc.new {|env|
  query_vars = Rack::Utils.parse_nested_query(env.fetch('QUERY_STRING'))
  query_millis = query_vars.fetch('millis').to_i
  sleep(query_millis / 1000.0)
  [200, {'content-type' => 'text/plain'}, ['That took a while']]
}

SlowServlet = Proc.new {|env|
  body = Enumerator.new do |y|
    y.yield 'x'
    sleep 5
    y.yield 'rest of body'
  end
  [200, {'content-type' => 'text/plain'}, body]
}

RedirectServlet = Proc.new {|env|
  url_scheme = env.fetch('rack.url_scheme')
  port = env.fetch('SERVER_PORT')
  [301, {'location' => "#{url_scheme}://localhost:#{port}/test"}, []]
}

EvilRedirectServlet = Proc.new {|env|
  [301, {'location' => "smtp://mailbox:secret@localhost"}, []]
}

BodyReadback = Proc.new {|env|
  body_str = JSON.generate({
    'request_method' => env['REQUEST_METHOD'],
    'body_base64' => [env['rack.input'].read].pack('m0'),
    'content_type' => env.fetch('CONTENT_TYPE'),
  })
  [200, {'content-type' => 'application/json'}, [body_str]]
}

SetCookieServlet = Proc.new {|env|
  [301, {'set-cookie' => 'session_id=foo123', 'location' => "#{env.fetch('rack.url_scheme')}://localhost:#{env.fetch('SERVER_PORT')}/test"}, []]
}

RepetitiveHeaderServlet = Proc.new {|env|
  [200, {'set-cookie' => ['a=1', 'b=2'], 'content-type' => 'text/plain'}, ['Hi.']]
}

PictureServlet = Proc.new {|env|
  # Rack::Files gives us Range support for free
  env_with_adjusted_path = env.merge('PATH_INFO' => '/pic.png')
  Rack::Files.new(__dir__).call(env_with_adjusted_path)
}

RedirectToPictureServlet = Proc.new {|env|
  [307, {'location' => '/picture'}, []]
}

# Keeps the method and the body, so the client has to send the body again
RedirectWithBodyServlet = Proc.new {|env|
  env['rack.input'].read
  [307, {'Location' => '/test'}, []]
}

WrongContentLengthServlet = Proc.new {|env|
  [200, {'content-length' => '1024', 'content-type' => 'text/plain'}, ['Hello.']]
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
  [200, {'content-type' => 'binary/octet-stream', 'content-length' => len.to_s}, body]
}

# Echoes the subject of the client certificate Puma verified, if any
PeerCertServlet = Proc.new {|env|
  subject = env['puma.peercert'] ? env['puma.peercert'].subject.to_s : 'none'
  [200, {'content-type' => 'text/plain', 'content-length' => subject.bytesize.to_s}, [subject]]
}

# Writes `count` chunks of `size` bytes, sleeping `delay` seconds between two chunks
SlowChunksServlet = Proc.new {|env|
  query = Rack::Utils.parse_nested_query(env['QUERY_STRING'])
  count = query.fetch('count', '5').to_i
  size = query.fetch('size', '1024').to_i
  delay = query.fetch('delay', '0.1').to_f
  body = Enumerator.new do |y|
    count.times do |i|
      sleep delay if i > 0
      y << ((97 + i % 26).chr * size)
    end
  end
  [200, {'content-type' => 'text/plain'}, body]
}

# Sends the head right away and the first byte of the body only after `delay` seconds. A Rack 3
# streaming body, since Puma holds back the head of an Enumerator body until its first chunk
LongPollServlet = Proc.new {|env|
  query = Rack::Utils.parse_nested_query(env['QUERY_STRING'])
  delay = query.fetch('delay', '1').to_f
  body = proc do |stream|
    sleep delay
    stream.write("first\n")
    stream.write("second\n")
  ensure
    stream.close
  end
  [200, {'content-type' => 'text/event-stream; charset=utf-8', 'x-long-poll' => 'yes'}, body]
}

# `lines` numbered lines, `per_chunk` of them in each chunk, so a client can check every byte
# arrived once and in order
CounterServlet = Proc.new {|env|
  query = Rack::Utils.parse_nested_query(env['QUERY_STRING'])
  lines = query.fetch('lines', '1000').to_i
  per_chunk = query.fetch('per_chunk', '100').to_i
  body = Enumerator.new do |y|
    0.step(lines - 1, per_chunk) do |from|
      y << (from...[from + per_chunk, lines].min).map { |i| format("%07d\n", i) }.join
    end
  end
  [200, {'content-type' => 'text/plain', 'content-length' => (lines * 8).to_s}, body]
}

# An error with a body, for draining
ErrorWithBodyServlet = Proc.new {|env|
  body = "x" * 4096
  [503, {'content-type' => 'text/plain', 'content-length' => body.bytesize.to_s}, [body]]
}

run Rack::URLMap.new({
  "/" => Proc.new {|env| [200, {'content-length' => '7'}, ['Welcome']]},
  "/test" => ReadbackServlet,
  "/testpost" => BodyReadback,
  "/testpatch" => BodyReadback,
  "/timeout" => TimeoutServlet,
  "/slow" => SlowServlet,
  "/redirect" => RedirectServlet,
  "/evil-redirect" => EvilRedirectServlet,
  "/picture" => PictureServlet,
  "/redirect-to-picture" => RedirectToPictureServlet,
  "/redirect-307" => RedirectWithBodyServlet,
  "/very-large" => LargeServlet,
  "/setcookie" => SetCookieServlet,
  "/repetitiveheader" => RepetitiveHeaderServlet,
  "/wrongcontentlength" => WrongContentLengthServlet,
  "/deflate-compressed" => DeflateServlet,
  "/peercert" => PeerCertServlet,
  "/slow-chunks" => SlowChunksServlet,
  "/long-poll" => LongPollServlet,
  "/counter" => CounterServlet,
  "/error-with-body" => ErrorWithBodyServlet,
})
