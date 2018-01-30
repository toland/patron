## -------------------------------------------------------------------
##
## Patron HTTP Client: HTTP test server for integration tests
require 'yaml'
require 'ostruct'

def to_fake_webrick_request(env)

end

Readback = ->(env) {
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
    :path => req.fullpath,
    :request_method => req.request_method.to_s,
    :header => Hash[req_headers],
    :body => env['rack.input'].read,
  })

  body_str = fake_webrick_request_object.to_yaml
  [200, {'Content-Type' => 'text/plain', 'Content-Length' => body_str.bytesize.to_s}, [body_str]]
}

GzipServlet = ->(env) {
  raise "Need to have the right Accept-Encoding: header" unless env['HTTP_ACCEPT_ENCODING']
  
  body = Enumerator.new do |y|
    z = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION)
    1024.times {
      y.yield(z.deflate('Some highly compressible data'))
    }
    y.yield(z.finish.to_s)
    y.yield(z.close.to_s)
  end

  [200, {'Content-Encoding' => 'deflate', 'Vary' => 'Accept-Encoding'}, body]
}

TimeoutServlet = ->(env) {
  sleep 1.1
  [200, {'Content-Type' => 'text/plain'}, ['That took a while']]
}

SlowServlet = ->(env) {
  body = Enumerator.new do |y|
    y.yield 'x'
    sleep 20
    y.yield 'rest of body'
  end
  [200, {'Content-Type' => 'text/plain'}, body]
}

RedirectServlet = -> (env) {
  port = env.fetch('SERVER_PORT')
  [301, {'Location' => "http://localhost:#{port}/test"}, []]
}

EvilRedirectServlet = -> (env) {
  port = env.fetch('SERVER_PORT')
  [301, {'Location' => "smtp://mailbox:secret@localhost"}, []]
}

BodyReadback = ->(env) {
  readback = {'method' => env['REQUEST_METHOD'], 'body' => env['rack.input'].read, 'content_type' => env.fetch('HTTP_CONTENT_TYPE')}
  [200, {'Content-Type' => 'text/plain'}, [readback]]
}

TestPatchBodyServlet = BodyReadback

SetCookieServlet = ->(env) {
  [301, {'Set-Cookie' => 'session_id=foo123', 'Location' => 'http://localhost:9001/test'}, []]
}

RepetitiveHeaderServlet = ->(env) {
  # The values of the header must be Strings,
  # consisting of lines (for multiple header values, e.g. multiple
  # <tt>Set-Cookie</tt> values) separated by "\\n".
  [200, {'Set-Cookie' => "a=1\nb=2", 'Content-Type' => 'text/plain'}, ['Hi.']]
}

PictureServlet = ->(env) {
  [200, {'Content-Type' => 'image/png'}, [File.read('./pic.png')]]
}

WrongContentLengthServlet = ->(env) {
  [200, {'Content-Length' => '1024', 'Content-Type' => 'text/plain'}, ['Hello.']]
}

# Serves a substantial amount of data
LargeServlet = ->(env) {
  len = 15 * 1024 * 1024
  body = Enumerator.new do |y|
    15.times do
      y.yield(Random.new.bytes(1024 * 1024))
    end
  end
  [200, {'Content-Type' => 'binary/octet-stream', 'Content-Length' => len.to_s}, body]
}

run Rack::URLMap.new({
  "/" => ->(*) { [200, {'Content-Length' => '2'}, ['Welcome']]},
  "/test" => Readback,
  "/testpost" => BodyReadback,
  "/testpatch" => BodyReadback,
  "/timeout" => TimeoutServlet,
  "/slow" => SlowServlet,
  "/redirect" => RedirectServlet,
  "/evil-redirect" => EvilRedirectServlet,
  "/picture" => PictureServlet,
  "/very-large" => LargeServlet,
  "/setcookie" => SetCookieServlet,
  "/repetitiveheader" => RepetitiveHeaderServlet,
  "/wrongcontentlength" => WrongContentLengthServlet,
  "/gzip-compressed" => GzipServlet,  
})
