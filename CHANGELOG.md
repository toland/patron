### 0.13.2

* Eagerly initialize libCURL handle when creating the Session instance instead of initializing it lazily
* Remove special treatment of `Session#reset` and make it the same as `Session#interrupt`

### 0.13.0, 0.13.1

* Permit timeouts to be set as a Float of seconds and use `CURLOPT_(CONNECT)TIMEOUT_MS` instead of `CURLOPT_(CONNECT)TIMEOUT` so that
  sub-second timeouts can be configured, which is useful for performant services using accelerated DNS resolution.
* Remove the restriction that `Session#timeout` should be non-zero - a timeout set to 0 means "no timeout" in libCURL

### 0.13.0

* Permit timeouts to be set as a Float of seconds and use `CURLOPT_(CONNECT)TIMEOUT_MS` instead of `CURLOPT_(CONNECT)TIMEOUT` so that
  sub-second timeouts can be configured, which is useful for performant services using accelerated DNS resolution.
* Remove the restriction that `Session#timeout` should be non-zero - a timeout set to 0 means "no timeout" in libCURL

### 0.12.1

* Ensure HTTP2 response headers/status lines are correctly handled

### 0.12.0

* Replace StringScanner in HeaderParser with StringIO, fix Webmock regression when the headers string would
  not have an empty CRLF-terminated line at the end - which would cause the parser to return a nil.
* Added `Session#dns_cache_timeout` as a config option for CURLOPT_DNS_CACHE_TIMEOUT

### 0.11.1

* Make sure StringScanner is available to HeaderParser.

### 0.11.0

* Added `Session#progress_callback` which accepts a callable object, which can be used to report session progress during request
  execution.
* Fixed parsing of response headers when multiple responses are involved (redirect chains and HTTP proxies)

### 0.10.0

* Added `Session#low_speed_time` and `Session#low_speed_limit`. When used, they will force libCURL to raise
  a timeout if a certain speed limit is not met performing the request. These can be used for better timeout
  handling. These are available in all libCURL versions. See https://curl.haxx.se/libcurl/c/CURLOPT_LOW_SPEED_TIME.html
  and https://curl.haxx.se/libcurl/c/CURLOPT_LOW_SPEED_LIMIT.html

### 0.9.1

* Added ssl_version options `TLSv1_1`, `TLSv1_2`, `TLSv1_3` for explicitly forcing the SSL version
    * requires the appropriate versions of libCURL and OpenSSL installed to support these new options 
    * reference: https://curl.haxx.se/libcurl/c/CURLOPT_SSLVERSION.html
* Added a new `:http_version` option with `HTTPv1_1` and `HTTPv2_0` values to explicitly set the HTTP version of HTTP/1.1 or HTTP/2.0
    * requires the appropriate versions of libCURL and OpenSSL installed to support these new options 
    * reference: https://curl.haxx.se/libcurl/c/CURLOPT_HTTP_VERSION.html
* Updates the gem release procedure for more convenience, using the updated Rubygems.org tasks
* Update a few minor dependencies and documentation to be Ruby 2.4.1-compatible, add 2.4.1. to Travis CI matrix
* Add `Session#download_byte_limit` for limiting the permitted download size.
  This can be very useful in dealing with untrusted download sources, which might attempt
  to send very large responses that would overwhelm the receiving client.
* Add `Patron.libcurl_version_exact` which returns a triplet of major, minor and patch libCURL version numbers. This can be used
  for more fine-grained matching when using some more esoteric Curl features which might not necessarily be available on libCURL
  Patron has been linked against.

### 0.8.0

* Add `Response#inspectable_body`, `Response#decoded_body`. `decoded_body` will atempt to decode
  the HTTP response into your internal encoding, using the charset header that the server has
  provided. Note that this operation may fail - if the server said that the body is in a certain
  encoding, but this is then overridden with, say, `meta` elements in the HTML Patron is _not_
  going to parse the HTML to figure out how to decode.

### 0.7.0

* Allow Ruby File objects to be passed as `data` to `Session#put`, `Sesion#post` etc.

### 0.6.5

* Prevent libCURL from doing requests to non-HTTP/HTTPS URLs, and from following redirects to such URLs

### 0.6.4

* Set the default User-Agent string, since some sites require it (like the Github API).
* Add Response#ok? and Response#error? for cleaner branching on the returned Response objects
* Explain a segfault with SSL in forked processes on OSX, document the way to avoid the issue
* Fix segfault when attempting multiple post requests with multipart (#119)

### 0.6.3

* Fix timeout when uploading a body using all verbs except POST
* Add PATCH HTTP verb support
* Populate the curl state object from the reader methods of `Request`

### 0.6.1

* Fix compilation on older versions of libCURL
* Fix cookie jar files not being saved after request
* Reformat the gem documentation to YARD, document a few behaviors

### 0.6.0

* Add `Patron::Session#automatic_content_encoding` for automatic deflate handling via `Accept`/`Content-Encoding`

### 0.5.1

* Allow customizing the class used for the response (now uses `Session#response_class` to determine the class at runtime)
* Do not fail body decoding if the charset name set in the header is invalid

### 0.5.0

* Optimise response header parsing
* Fix a bug with `Session#base_url` being empty
* Fix memory corruption when Ruby would free a Patron buffer uninteltionally
* Modernize the wrapper for request execution, unlock the GVL if possible using the C function native to the version of Ruby we build on
* Add an option to force CURL to only use IPv4 (`Session#force_ipv4`)
* Fix a few bugs with base_url concatenation
* Support options- and block-constructor for `Session.new`
* Allow the `Request` object to be customized

### 0.4.20

* Revert the HTTP verb to be a Symbol, but allow uppercase versions

### 0.4.19

* Add an option to set `Session#ssl_version` (uses a String as value)
* Fix `Session#insecure`
* Add request body support for DELETE requests
* Add support for default headers via `Session#headers`
* Allow customizing the CA root file for SSL requests via `Session#cacert`
* Add gzip encoding support by setting explicit headers
* Allow `Session#base_url` to be overridden on a per-request basis
* Use binary mode flags in `fopen()` for `get_file` to improve Windows compatibility

### 0.4.18

* Handle GET request body via buffers, not via post fields

### 0.4.17

* Use libCURL for doing URL encoding
* Add `Session#interrupt`, which can be used to stop the request/response from another thread
* Add `Session#reset` to explicitly clear out the libCURL state
* Use sglib to register all running CURL sessions, to allow them to terminate rapidly when the host Ruby process exits abruptly, via interrupt or otherwise
* Use a test server in an external process when running rspec
* Ensure responses that are not text do not force response body decoding
* Improve thread blocking region handling during requests

### 0.4.17

* Tweak response decoding

### 0.4.15

* Remove rvm/rbenv service files from the repo
* Encode the response attributes based on the response charset
* Fix urlencode for Ruby 1.9 compatibility
* Enable Hash as argument for `Session#post`, which will be form-encoded
* Allow "timeout" and other options to be overridden at request instantiation

### 0.4.14

* Fix ignore_content_length/ignore_content_size inconsistency
* Fix a few OSX compilation snags, do not force ARCHFLAGS

### 0.4.13

* Add `Session#ignore_content_length`

### 0.4.12

* Add `:query` option to `Session#request`, encode query parameters from a Hash of options when doing `Session#get`

### 0.4.11

* Add URL encoding when an action is a POST
* Upgrade build system and rspec

### 0.4.10

* Make the curl buffer size advisory customizable.
* Add SOCKS proxy support
* Add `Session#enable_debug` that will write debug info to a file or to STDERR

### 0.4.9

* Use rb_hash_foreach for better jRuby/Rubinius compat

### 0.4.8

* Remove Rubyforge build tasks
* Run the test server under 1.8 if the main test runs under 1.8
* Fix incorrect usage of `rb_define_const`

### 0.4.7

* Fix incorrect usage of `rb_define_const`
* Preserve multiple headers with the same name (like `Set-Cookie`)
* Set `Expect` in the request to an empty string, to prevent upload hangs
* Fix a call to `rb_raise` when raising exceptions

### 0.4.5

* Fix use with threads on 1.9.1
* Specify connection timeout in seconds, not in millis
* Default max redirects to 5

### 0.4.4

* Fix a string comparison bug in `enable_cookie_session()`
* Raise an ArgumentError if no data or filename is provided to PUT or
POST

### 0.4.3

* Add `Session#insecure` to bypass cert validation (defaults to off)
* Add a blocking region for 1.9 GIL
* Allow setting `Session#timeout` to `nil` to disable timeouts outright

### 0.4.2

* Fix rubyforge release tasks
* Add simple cookie handling
* More 1.9 compatibility
* Set a default `Session#auth_type` to be HTTP Basic (`:basic`)

### 0.4.1

* Add HTTP Digest authentication support
* Allow `Request` to use a Hash for body, using options

### 0.4.0

* Documentation tweaks
* Add support for the COPY HTTP verb
* Make sure C helper functions are static
* Make `Session#request` public
* Add `get_file` to write the response body to a file outside of the Ruby heap
* Add initial HTTP prox suport
* Add license, copyright

### 0.3.0

* Add connection timeout support

### 0.2.0

* Initial tagged release
