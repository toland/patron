# Ruby HTTP Client

## SYNOPSIS

Patron is a Ruby HTTP client library based on libcurl. It does not try to expose
the full "power" (read complexity) of libcurl but instead tries to provide a
sane API while taking advantage of libcurl under the hood.


## USAGE

Usage is very simple. First, you instantiate a Session object. You can set a few
default options on the Session instance that will be used by all subsequent
requests:

    sess = Patron::Session.new
    sess.timeout = 10
    sess.base_url = "http://myserver.com:9900"
    sess.headers['User-Agent'] = 'myapp/1.0'
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

That is pretty much all there is to it.


## REQUIREMENTS

You need a recent version of libcurl in order to install this gem. On MacOS X
the provided libcurl is sufficient. You will have to install the libcurl
development packages on Debian or Ubuntu. Other Linux systems are probably
similar. Windows users are on your own. Good luck with that.


## INSTALL

    sudo gem install patron


Copyright (c) 2008 The Hive
