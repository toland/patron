# Patron

[![Tests](https://github.com/toland/patron/actions/workflows/ci.yml/badge.svg)](https://github.com/toland/patron/actions/workflows/ci.yml)

Patron is a Ruby HTTP client library based on libcurl. It does not try to expose
the full "power" (read complexity) of libcurl but instead tries to provide a
sane API while taking advantage of libcurl under the hood.

## Usage

First, you instantiate a Session object. You can set a few
default options on the Session instance that will be used by all subsequent
requests:

```ruby
sess = Patron::Session.new
sess.timeout = 10
sess.base_url = "http://myserver.com:9900"
sess.headers['User-Agent'] = 'myapp/1.0'
```

You can set options with a hash in the constructor:

```ruby
sess = Patron::Session.new(timeout: 10,
                           base_url: 'http://myserver.com:9900',
                           headers: {'User-Agent' => 'myapp/1.0'})
```

Or the set options in a block:

```ruby
sess = Patron::Session.new do |patron|
    patron.timeout = 10
    patron.base_url = 'http://myserver.com:9900'
    patron.headers = {'User-Agent' => 'myapp/1.0'}
end
```

Output libcurl's verbose log to a file, to any IO, or to `$stderr` when called without arguments:

```ruby
sess.enable_debug "/tmp/patron.debug"
sess.enable_debug $stdout
```

The Session is used to make HTTP requests.

```ruby
resp = sess.get("/foo/bar")
```

Requests return a Response object:

```ruby
if resp.status < 400
  puts resp.body
end
```

The GET, HEAD, PUT, PATCH, POST and DELETE operations have their own methods, and any other
HTTP verb can be sent through `request`:

```ruby
sess.put("/foo/baz", "some data")
sess.delete("/foo/baz")
sess.request(:propfind, "/foo", {"Depth" => "1"})
```

A failed transfer raises a subclass of `Patron::Error` (`Patron::TimeoutError`, `Patron::ConnectionFailed`,
`Patron::HostResolutionError` and so on). Every such error carries the libcurl error code as `curl_code`.

You can ship custom headers with a single request:

```ruby
sess.post("/foo/stuff", "some data", {"Content-Type" => "text/plain"})
```

libcurl's transfer timings are available on the response, in seconds since the request started:

```ruby
resp = sess.get("/foo/bar")
resp.timings # => {namelookup: 0.001, connect: 0.012, appconnect: 0.045, pretransfer: 0.045,
             #     starttransfer: 0.210, redirect: 0.0, total: 0.214}
```

To authenticate with a client certificate (mutual TLS), point Patron at a PKCS#12 bundle:

```ruby
sess.ssl_cert = "/path/to/client.p12"
sess.ssl_cert_type = "P12"
sess.ssl_key_password = "secret"
```

or at a PEM certificate with a separate private key:

```ruby
sess.ssl_cert = "/path/to/client.pem"
sess.ssl_key = "/path/to/client_key.pem"
sess.ssl_key_password = "secret" # if the key is encrypted
```

If the certificate or key can't be loaded (wrong password, missing file) the request raises `Patron::ClientCertificateError`.
This depends on the TLS library libcurl is built against: with GnuTLS these surface as a plain `Patron::Error`.
Client certificates are tested with the OpenSSL and LibreSSL backends - libcurl's Secure Transport backend
can't load a PEM certificate from a file at all.

## Threading

A `Patron::Session` performs one request at a time and must not be shared between threads: each `Session`
owns its own libcurl handles and buffers, and using it from two threads at once raises `Patron::Error`.
Patron releases the GVL (the global VM lock) whenever it waits for the network, so using one `Session`
per thread gives you real parallelism.
For sharing a pool of sessions between threads we recommend the excellent [connection_pool](https://rubygems.org/gems/connection_pool) gem by Mike Perham.

```ruby
patron_pool = ConnectionPool.new(size: 5, timeout: 5) { Patron::Session.new }
patron_pool.with do |session|
  session.get(...)
end
```

Sharing Session objects between requests will also allow you to benefit from persistent connections (connection reuse), see below.

## Persistent connections

Every `Session` owns a libcurl multi handle with its own connection cache, plus a share handle for
cookies, DNS entries and TLS sessions. If you create the Session once and use it for multiple requests
to the same hostname/port/protocol, the connection gets reused, following libcurl's rules on
[connection reuse.](https://everything.curl.dev/libcurl/connectionreuse.html)

## Interrupting requests

A request in flight can be aborted from another thread with `Session#interrupt`, after which the
request raises `Patron::Aborted`. `Thread#kill`, `Thread#raise`, `Timeout.timeout` and signals interrupt
a request the same way, immediately and in any phase of the transfer, including DNS resolution and
connecting. A `progress_callback` that returns `false` aborts the request as well, and an exception
raised inside the callback propagates out of the request once libcurl is done with it.

## Fibers and the async gem

When a Fiber scheduler is installed for the current thread (as inside `Async { }`), Patron hands the
wait for the network to the scheduler instead of blocking the thread, so requests from several fibers
overlap and other fibers keep running while one waits:

```ruby
Async do |task|
  pages = urls.map { |url| task.async { Patron::Session.new(timeout: 10).get(url) } }.map(&:wait)
end
```

Each fiber needs its own `Session`, just like each thread does. `Async::Task#stop` and
`Task#with_timeout` interrupt a request in flight the same way `Thread#kill` and `Timeout` do.

## Ractors

Patron works from non-main Ractors, so Ractors give you parallelism for the Ruby side of your
requests as well, not just for the waits. A `Session` belongs to the Ractor that created it: Ruby refuses
to copy, move or share one (`Ractor::Error`), so create the `Session` inside the Ractor and ship
`Response` objects out. A worker pool looks like this on Ruby 4.0:

```ruby
results = Ractor::Port.new
workers = 4.times.map do
  Ractor.new(results) do |results|
    session = Patron::Session.new(timeout: 10)
    while (url = Ractor.receive)
      results << Ractor.make_shareable(session.get(url))
    end
  end
end
urls.each_with_index { |url, i| workers[i % workers.size].send(url) }
responses = urls.size.times.map { results.receive }
```

`Ractor.make_shareable` on the `Response` is optional: it saves copying the body when the Response crosses
over, and a shareable (frozen) `Response` still decodes its body. A `Patron::Error` raised inside the
Ractor comes out of `Ractor#value` as the `cause` of a `Ractor::RemoteError`, `curl_code` and all.
`Patron::Request` objects can be made shareable and used from any Ractor too.

## How the GVL is handled

Patron drives libcurl through its multi interface. The part of libcurl that moves bytes
(`curl_multi_perform`) runs with the GVL held, which is what makes it safe to run your progress callback
and to write straight into Ruby Strings from inside libcurl. Whenever libcurl has nothing to do but wait
for the network, Patron releases the GVL (`curl_multi_poll`), so other Ruby threads run in parallel with
the transfer, and that wait is what Ruby interrupts when it needs the thread back.

## Requirements

Patron 1.0 and up requires Ruby 3.3 or newer and libcurl 7.81.0 or newer (Ubuntu 22.04 and up,
Debian 12 and up, any current macOS). The 0.x versions support older Rubies and stay on the `v0.x` branch.

You will have to install the libcurl development package on Debian or Ubuntu (`libcurl4-openssl-dev`),
Alpine (`curl-dev`) and the like. The build looks libcurl up through `pkg-config`, then `curl-config`,
then the default include and library paths. To build against a specific libcurl, for example
Homebrew's OpenSSL-backed one instead of the SecureTransport-backed one macOS ships:

    $ gem install patron -- --with-curl-dir=$(brew --prefix curl)

or, for every Bundler-driven install:

    $ bundle config build.patron --with-curl-dir=$(brew --prefix curl)

The SecureTransport backend of the macOS system libcurl cannot load PEM client certificates,
and [older versions of it crash](https://github.com/curl/curl/issues/788) when doing HTTPS in a forked
subprocess, so the Homebrew libcurl is the better choice on macOS.

## Installation

    gem install patron

Copyright (c) 2008 The Hive
