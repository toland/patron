# Patron

[![Build Status](https://travis-ci.org/toland/patron.svg?branch=master)](https://travis-ci.org/toland/patron)

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
sess = Patron::Session.new({ :timeout => 10,
                             :base_url => 'http://myserver.com:9900',
                             :headers => {'User-Agent' => 'myapp/1.0'} } )
```

Or the set options in a block:

```ruby
sess = Patron::Session.new do |patron|
    patron.timeout = 10
    patron.base_url = 'http://myserver.com:9900'
    patron.headers = {'User-Agent' => 'myapp/1.0'}
end
```

Output debug log:

```ruby
sess.enable_debug "/tmp/patron.debug"
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

The GET, HEAD, PUT, POST and DELETE operations are all supported.

```ruby
sess.put("/foo/baz", "some data")
sess.delete("/foo/baz")
```

You can ship custom headers with a single request:

```ruby
sess.post("/foo/stuff", "some data", {"Content-Type" => "text/plain"})
```

## Threading

By itself, the `Patron::Session` objects are not thread safe (each `Session` holds a single `curl_state` pointer
from initialization to garbage collection). At this time, Patron has no support for `curl_multi_*` family of functions 
for doing concurrent requests. However, the actual code that interacts with libCURL does unlock the RVM GIL,
so using multiple `Session` objects in different threads actually enables a high degree of parallelism.
For sharing a resource of sessions between threads we recommend using the excellent [connection_pool](https://rubygems.org/gems/connection_pool) gem by Mike Perham.

```ruby
patron_pool = ConnectionPool.new(size: 5, timeout: 5) { Patron::Session.new }
patron_pool.with do |session|
  session.get(...)
end
```

Sharing Session objects between requests will also allow you to benefit from persistent connections (connection reuse), see below.

## Persistent connections

Patron follows the libCURL guidelines on [connection reuse.](https://ec.haxx.se/libcurl-connectionreuse.html) If you create the Session
object once and use it for multiple requests, the same libCURL handle is going to be used across these requests and if requests go to
the same hostname/port/protocol the connection should get reused.

## Performance with parallel requests

When performing the libCURL request, Patron goes out of it's way to unlock the GVL (global VM lock) to allow other threads to be scheduled
in parallel. The GVL is going to be released when the libCURL request starts, and will then be shortly re-acquired to provide the progress
callback - if the callback has been configured, and then released again until the libCURL request has been performed and the response has
been read in full. This allows one to execute multiple libCURL requests in parallel, as well as perform other activities on other MRI threads
that are currently active in the process.

## Requirements

Patron 1.0 and up requires MRI Ruby 2.3 or newer. The 0.x versions support
Ruby 1.9.3 and these versions get tagged and developed on the `v0.x` branch.

A recent version of libCURL is required. We recommend at least 7.19.4 because
it [supports limiting the protocols](https://curl.haxx.se/libcurl/c/CURLOPT_PROTOCOLS.html),
and that is very important for security - especially if you follow redirects. 

On OSX the provided libcurl is sufficient if you are not using fork+SSL combination (see below).
You will have to install the libcurl development packages on Debian or Ubuntu. Other Linux systems are probably
similar. For Windows we do not have an established build instruction at the moment, unfortunately.

## Forking webservers on macOS and SSL

Currently, [an issue is at play](https://github.com/curl/curl/issues/788) with OSX builds of `curl` which use
Apple's SecureTransport. Such builds (which Patron is linking to), are causing segfaults when performing HTTPS
requests in forked subprocesses. If you need to check whether your system is affected,
run the Patron test suite by performing

    $ bundle install && bundle exec rspec

in the Patron install directory. Most default curl configurations on OSX (both
the Apple-shipped version and the version available via Homebrew) are linked to
SecureTransport and are likely to be affected. This issue may also manifest in
forking webserver implementations (such as Unicorn or Passenger) and in forking
job execution engines (such as resque), so even though you may not be using
`fork()` directly your server engine might be doing it for you.

To circumvent the issue, you need to build `curl` with OpenSSL via homebrew.
When doing so, `curl` will use openssl as it's SSL driver. You also need to
change the Patron compile flag:


    $ brew install curl-openssl && \
        gem install patron -- --with-curl-config=/usr/local/opt/curl-openssl/bin/curl-config

You can also save this parameter for all future Bundler-driven gem installs by
setting this flag in Bundler proper:

    $ bundle config build.patron --with-curl-config=/usr/local/opt/curl-openssl/bin/curl-config

## Installation

    sudo gem install patron

Copyright (c) 2008 The Hive
