Patron is a Ruby HTTP client library based on libcurl. It does not try to expose
the full "power" (read complexity) of libcurl but instead tries to provide a
sane API while taking advantage of libcurl under the hood.

## Usage

First, you instantiate a Session object. You can set a few
default options on the Session instance that will be used by all subsequent
requests:

    sess = Patron::Session.new
    sess.timeout = 10
    sess.base_url = "http://myserver.com:9900"
    sess.headers['User-Agent'] = 'myapp/1.0'

You can set options with a hash in the constructor:

    sess = Patron::Session.new({ :timeout => 10,
                                 :base_url => 'http://myserver.com:9900',
                                 :headers => {'User-Agent' => 'myapp/1.0'} } )

Or the set options in a block:

    sess = Patron::Session.new do |patron|
        patron.timeout = 10
        patron.base_url = 'http://myserver.com:9900'
        patron.headers = {'User-Agent' => 'myapp/1.0'}
    end

Output debug log:

    sess.enable_debug "/tmp/patron.debug"

The Session is used to make HTTP requests.

    resp = sess.get("/foo/bar")

Requests return a Response object:

    if resp.status < 400
      puts resp.body
    end

The GET, HEAD, PUT, POST and DELETE operations are all supported.

    sess.put("/foo/baz", "some data")
    sess.delete("/foo/baz")

You can ship custom headers with a single request:

    sess.post("/foo/stuff", "some data", {"Content-Type" => "text/plain"})

## Threading

By itself, the `Patron::Session` objects are not thread safe (each `Session` holds a single `curl_state` pointer
during the request/response cycle). At this time, Patron has no support for `curl_multi_*` family of functions 
for doing concurrent requests. However, the actual code that interacts with libCURL does unlock the RVM GIL,
so using multiple `Session` objects in different threads is possible with a high degree of concurrency.
For sharing a resource of sessions between threads we recommend using the excellent [connection_pool](https://rubygems.org/gems/connection_pool) gem by Mike Perham.

    patron_pool = ConnectionPool.new(size: 5, timeout: 5) { Patron::Session.new }
    patron_pool.with do |session|
      session.get(...)
    end

## Requirements

You need a recent version of libcurl in order to install this gem. On MacOS X
the provided libcurl is sufficient. You will have to install the libcurl
development packages on Debian or Ubuntu. Other Linux systems are probably
similar. Windows users are on your own. Good luck with that.

## Installation

    sudo gem install patron


Copyright (c) 2008 The Hive
