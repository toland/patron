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

A request body can be a String, a File (uploaded straight from disk by libcurl) or anything that
responds to `readpartial` or `read`, which is streamed. With `readpartial` a pipe or a socket goes out
as soon as something is written to it. A body without a `size` goes out with chunked transfer-encoding,
unless you pass a `Content-Length` header:

```ruby
reader, writer = IO.pipe
Thread.new { 3.times { |i| writer.write("line #{i}\n") }; writer.close }
sess.put("/foo/log", reader)
sess.post("/foo/stuff", StringIO.new("some data"))
```

If the body has to be sent again (a 307 redirect, say) Patron rewinds it with `seek`,
and a body that can't be rewound, like a pipe, fails the request with a `Patron::Error`.

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

## Streaming responses

`Session#stream` (and `get_stream`, `post_stream`, `put_stream`, `patch_stream`) yields the response as
soon as its head has arrived, and the block receives the body by reading from it. Nothing is buffered
meanwhile: every read drives libcurl until some bytes have arrived. `timeout` still bounds the whole
transfer, so set it to 0 and use `read_timeout` to bound the wait for each next piece:

```ruby
stats = sess.get_stream("/events", { "Accept" => "text/event-stream" }, timeout: 0, read_timeout: 30) do |stream|
  raise "Unexpected #{stream.status}" unless stream.ok? && stream.content_type == "text/event-stream"
  stream.each_line do |line|
    puts line.force_encoding(Encoding::UTF_8)
  end
end
stats.complete?  # => true when the body was received to its end
stats.timings    # the same Hash as Response#timings
stats.trailers   # chunked or HTTP/2 trailers, {} when none
```

`read(length, buffer)` and `readpartial(length, buffer)` fill a String you own, so copying a body
somewhere allocates nothing per chunk. `IO.copy_stream` uses exactly that, into a File or anything
with `write`:

```ruby
sess.get_stream("/large.bin") do |stream|
  raise "Too big" if stream.content_length.to_i > 1024 * 1024 * 1024
  File.open("large.bin", "wb") { |file| IO.copy_stream(stream, file) }
end
```

Leaving the block early (`break`, `return`, an exception) aborts the transfer and closes its connection;
call `stream.drain!` first to receive and discard the rest and keep the connection. Using the stream after
its block raises `IOError`. The block is mandatory, and the `Session` is busy while it runs. Under a Fiber
scheduler use `each` and `each_line` with a block rather than an external `Enumerator`.

### Server-sent events

`Patron::SSEClient` reads a `text/event-stream` on top of `stream`, and reconnects the way a browser's
EventSource does: after the retry interval (the server's `retry:` field wins), sending `Last-Event-ID`.

```ruby
client = Patron::SSEClient.new(
  "https://example.com/stream",
  headers: { "Authorization" => "Bearer ..." },
  idle_timeout: 45,     # seconds of silence before reconnecting
  retry: 3,             # seconds between reconnects until the server sends a retry field
  max_reconnects: nil,  # nil: forever
  last_event_id: nil,   # resume from a stored id
  session: nil          # or a configured Patron::Session: TLS, proxy, auth, cookies, base_url
)

client.each_event do |event|
  event.type  # "message" unless the server sent an event: field
  event.data  # data: lines joined with "\n", UTF-8
  event.id
  break if event.type == "done"
end
client.last_event_id  # to persist between process runs
```

A 204 ends `each_event`. Any other status than 200, or another Content-Type, raises
`Patron::SSEClient::UnexpectedResponse` with the `status`, `headers` and first 4 KB of `body`, since retrying
a 503 is the application's call. An event that is not valid UTF-8 raises `Patron::SSEClient::InvalidEncoding`
and ends the stream, where a browser would substitute U+FFFD. `client.close` from another thread or fiber makes
`each_event` return.

The client only issues GETs, like an `EventSource`. For an event stream that answers a POST, which is how the
LLM completion APIs stream, run the same parser over the body yourself:

```ruby
session.post_stream("/v1/chat/completions", body.to_json, headers) do |stream|
  raise "status #{stream.status}" unless stream.status == 200
  Patron::SSEClient.parse(stream) do |event|
    break if event.data == "[DONE]"
    print JSON.parse(event.data).dig("choices", 0, "delta", "content")
  end
end
```

`Patron::SSEClient.parse` takes anything with `readpartial`, so a file or a socket works as well as a
`ResponseStream`, and returns the last event ID it saw.

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

A checked-out Session can run several requests at once as a pack, see [Parallel requests](#parallel-requests).

## Persistent connections

Every `Session` owns a libcurl multi handle with its own connection cache, plus a share handle for
cookies, DNS entries and TLS sessions. If you create the Session once and use it for multiple requests
to the same hostname/port/protocol, the connection gets reused, following libcurl's rules on
[connection reuse.](https://everything.curl.dev/libcurl/connectionreuse.html)

## Parallel requests

Requests that do not depend on each other can go out together. `Session#multi` returns a
`Patron::Multi`, a pack with the same verb methods, defaults, headers and cookie jar as the Session it came
from. Every verb call starts its request right away (on a warm connection it is on the wire before the call
returns) and hands back a `Patron::Transfer`: the request in flight, which you hold on to, join, and take the
response out of. `join` on a transfer drives the whole pack until that one is done, like `Thread#join`;
`join_all` on the pack drives until all of them are.

```ruby
multi   = sess.multi
account = multi.get("/accounts/#{id}")
orders  = multi.get("/accounts/#{id}/orders")
audit   = multi.post("/audit", event: "viewed", account: id)

account.join.response.body
orders.join.response.status
multi.join_all           # for audit and anything else still in flight
```

The three requests take as long as the slowest one, not the sum, and towards an HTTP/2 server they all
share one connection. A `Transfer` knows where it stands:

```ruby
account.done?        # finished, one way or the other
account.succeeded?   # done, and the Response is there
account.failed?      # done, and account.error has the Patron::Error
account.join         # blocks until this one is done, driving the whole pack meanwhile. Returns self,
                     # or raises the request's Patron::Error if it failed, like Thread#join does
account.join(2)      # the same, but gives up after two seconds and returns nil, like Thread#join(limit)
account.response     # the Response; raises the request's Patron::Error if it failed,
                     # and Patron::InFlight if it is not done yet
account.error        # the Patron::Error, or nil
account.request      # the Patron::Request it was built from
account.interrupt    # aborts just this one; it then fails with Patron::Aborted
```

`join_all` does not raise when a request fails, since there is no one error to raise and raising one would hide
the others, which is why it is not called `join`. The error surfaces where you join or read that transfer:

```ruby
limits = multi.request(:get, "/accounts/#{id}/limits", {}, timeout: 2)
begin
  limits.join.response.body
rescue Patron::TimeoutError
  nil
end

multi.join_all
multi.select(&:failed?).each { |transfer| logger.warn("#{transfer.request.url}: #{transfer.error.message}") }
```

`Patron::InFlight` is not a `Patron::Error`: asking for a response before joining is a mistake in the
program, not a failure of the request, and `rescue Patron::Error` must not swallow it.

A `Multi` is `Enumerable` over its transfers in completion order, and `each` drives the pack itself, so no
`join_all` is needed before it. The block runs between libcurl's own iterations, never inside one, so it may do
anything:

```ruby
multi = sess.multi
urls.each { |url| multi.get(url) }
multi.each do |transfer|
  next if transfer.failed?
  File.binwrite(File.basename(transfer.request.url), transfer.response.body)
end
```

The block form of `multi` yields the pack, calls `join_all`, and returns it. `transfers` is every transfer in the order
it was added, which pairs well with `zip`:

```ruby
pack = sess.multi { |m| urls.each { |url| m.get(url) } }
urls.zip(pack.transfers).each { |url, transfer| puts "#{url}: #{transfer.response.status}" }
```

Requests built elsewhere, with `build_request` or taken from a finished transfer, are added with `<<`, which
also returns the `Transfer`. Per-request options such as `timeout:`, `download_byte_limit:` and
`progress_callback:` apply to that request alone, and `max_connections:` on `multi` caps the connections the
pack may open, which matters toward HTTP/1.1 servers that do not multiplex:

```ruby
multi = sess.multi(max_connections: 4)
transfers = ids.map { |id| multi << sess.build_request(:get, "/items/#{id}", timeout: 2) }
multi.join_all
```

The Session is busy from the first verb call until every transfer of the pack is done, the same way it is
busy during a single request, so another thread or fiber using it raises `Patron::Error` as usual. Once all
are done the Session is free again, for plain requests or for another round on the same pack. `close` ends a
pack early, aborting what is still in flight. `Session#interrupt` and `Multi#interrupt` abort every transfer
in the pack, and `Thread#raise`, `Timeout.timeout` and `Async::Task#stop` interrupt a `join` the way they
interrupt a single request. The bodies of buffered transfers are received into memory, each bounded by its
`download_byte_limit`.

### Streams in a pack

The streaming verbs are on the pack too, with the same block as on a Session. The block receives the same
`Patron::ResponseStream` once the head has arrived, and runs while the pack is driven: by `join_all`, by `each`,
or by a `join` on any transfer of the pack. Each block runs in a fiber of its own, so several streams are
consumed interleaved, each as fast as its own bytes come, next to the buffered requests of the same pack:

```ruby
multi = sess.multi
meta  = multi.get("/accounts/#{id}")
alice = multi.get_stream("/accounts/1/events") { |s| s.each_line { |line| handle(:alice, line) } }
bob   = multi.get_stream("/accounts/2/events") { |s| s.each_line { |line| handle(:bob, line) } }
multi.join_all

meta.response.body
alice.stats          # => Patron::TransferStats, the receipt, as Session#stream returns it
alice.stats.complete?
```

A streamed transfer is done when its block has returned. Its receipt is `stats` rather than `response`, like
`Session#stream`; reading it before the block has returned raises `Patron::InFlight`. `join` means done for
streams as well: the whole body, not just the head. A failure mid-body raises inside the block, out of the
read that hit it, as it does with `Session#stream`; the transfer is then `failed?` with that error.

An exception the block itself raises fails the transfer. A `Patron::Error` stays with the transfer, to be
re-raised by its `join`; anything else also comes out of the `join`, `join_all` or `each` that was driving the
pack at the time. This is deliberate: the block runs on the joining thread, and `Timeout.timeout` or
`Thread#raise` aimed at the join can land while a block runs, which must not be mistaken for a request
failure. The other transfers are unaffected, and joining again carries on with them.

The fibers the blocks run in are plain, blocking fibers: IO the block does on its own blocks the thread, also
inside Async, rather than yielding to the scheduler. Joining a transfer from inside a block raises
`Patron::Error`: the block is already being driven. A stream left running when the pack is closed is unwound
with `Patron::Aborted`, so its `ensure` clauses run. Bound a stream with `read_timeout` rather than `timeout`,
as with `Session#stream`: the whole-transfer timeout keeps counting while the stream waits for its block.

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
`Task#with_timeout` interrupt a request in flight the same way `Thread#kill` and `Timeout` do, and
`Session#interrupt` and `SSEClient#close` from another fiber reach the waiting one at once.

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
