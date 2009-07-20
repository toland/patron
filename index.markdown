---
layout: default
title: Patron - A Fast HTTP Client for Ruby
---

Patron is a Ruby HTTP client library based on libcurl. It does not try to expose
the full "power" (read complexity) of libcurl but instead tries to provide a
sane API while taking advantage of libcurl under the hood.


<h3><a name="#usage">USAGE</a></h3>

Usage is very simple. First, you instantiate a Session object. You can set a few
default options on the Session instance that will be used by all subsequent
requests:

{% highlight ruby %}
    sess = Patron::Session.new
    sess.timeout = 10
    sess.base_url = "http://myserver.com:9900"
    sess.headers['User-Agent'] = 'myapp/1.0'
{% endhighlight %}

The Session is used to make HTTP requests.

{% highlight ruby %}
    resp = sess.get("/foo/bar")
{% endhighlight %}

Requests return a Response object:

{% highlight ruby %}
    if resp.status < 400
      puts resp.body
    end
{% endhighlight %}

The GET, HEAD, PUT, POST and DELETE operations are all supported.

{% highlight ruby %}
    sess.put("/foo/baz", "some data")
    sess.delete("/foo/baz")
{% endhighlight %}

You can ship custom headers with a single request:

{% highlight ruby %}
    sess.post("/foo/stuff", "some data", {"Content-Type" => "text/plain"})
{% endhighlight %}

That is pretty much all there is to it.

<h3><a name="#installation">INSTALLATION</a></h3>

    sudo gem install patron


<h3><a name="#requirements">REQUIREMENTS</a></h3>

You need a recent version of libcurl in order to install this gem. On MacOS X
the provided libcurl is sufficient. You will have to install the libcurl
development packages on Debian or Ubuntu. Other Linux systems are probably
similar. Windows users are on your own. Good luck with that.
