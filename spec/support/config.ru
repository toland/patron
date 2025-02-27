require 'yaml'
require 'ostruct'
require 'zlib'

## HTTP test server for integration tests

Readback = Proc.new {|env|
  # The Patron test suite is originally written to enable the following
  # testing pattern:
  # * Patron does a request
  # * The request gets captured by Webrick
  # * Webrick then takes it's Request object and YAMLs it wholesale (body, headers and all)
  # * ...and sends it back to the client
  # * The test suite then de-YAMLs the request object from the response body and does assertions on it
  #
  # The easiest way to fake it, preserving the entire test suite intact, is to simulate a Webrick
  # request object using an ostruct. Of note is the following:
  #
  # 1) Webrick returns headers in arrays by default, accounting for repeats like with Cookie
  # 2) Webrick does not convert headers to ENV_VARS_FOR_FCI it only downcases them. We have to match that.
  req = Rack::Request.new(env)
  req_headers = env.to_a.select do |(k,v)|
    k.is_a?(String) && v.is_a?(String)
  end.map do |(k,v)|
   [k.downcase.gsub(/^http_/, '').gsub(/_/o, '-'), [v]]
  end

  fake_webrick_request_object = OpenStruct.new({
    :fullpath => req.fullpath,
    :path => req.path,
    :query_string => req.query_string,
    :request_method => req.request_method.to_s,
    :header => Hash[req_headers],
    :body => env['rack.input'].read,
  })

  body_str = fake_webrick_request_object.to_yaml
  [200, {'Content-Type' => 'text/plain', 'Content-Length' => body_str.bytesize.to_s}, [body_str]]
}

GzipServlet = Proc.new {|env|
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
  readback = {'method' => env['REQUEST_METHOD'], 'body' => env['rack.input'].read, 'content_type' => env.fetch('CONTENT_TYPE')}
  [200, {'Content-Type' => 'text/plain'}, [OpenStruct.new(readback).to_yaml]]
}

TestPatchBodyServlet = BodyReadback

SetCookieServlet = Proc.new {|env|
  [301, {'Set-Cookie' => 'session_id=foo123', 'Location' => 'http://localhost:9001/test'}, []]
}

RepetitiveHeaderServlet = Proc.new {|env|
  # The values of the header must be Strings,
  # consisting of lines (for multiple header values, e.g. multiple
  # <tt>Set-Cookie</tt> values) separated by "\\n".
  [200, {'Set-Cookie' => "a=1\nb=2", 'Content-Type' => 'text/plain'}, ['Hi.']]
}

PictureServlet = Proc.new {|env|
  # Rack::File allows us to test Range support as well
  env_with_adjusted_path = env.merge('PATH_INFO' => Rack::Utils.escape('/pic.png'))
  Rack::File.new('./').call(env_with_adjusted_path)
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

run Rack::URLMap.new({
  "/" => Proc.new {|env| [200, {'Content-Length' => '2'}, ['Welcome']]},
  "/test" => Readback,
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
  "/gzip-compressed" => GzipServlet,  
})
