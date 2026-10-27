### 1.0.0 (unreleased)

Patron 1.0 is a rewrite of the C extension for modern Ruby and modern libcurl, following the Ruby core
team's guidance in `doc/efficient_extensions.md`. It requires **Ruby 3.3+** and **libcurl 7.81+**.

**Transfers**

* A `Session` used inside a Fiber scheduler (`Async { }`, Falcon) yields to the scheduler while libcurl
  waits for the network instead of blocking the thread, so requests from several fibers overlap and
  `Async::Task#stop` / `with_timeout` interrupt a request cleanly. No API change, nothing to configure

* Requests are driven through libcurl's multi interface: every `Session` owns a multi handle with its own
  connection cache (connection pooling, #138), `curl_multi_perform` runs with the GVL held and only
  `curl_multi_poll` releases it, and `curl_multi_wakeup` is the unblocking function. `Thread#kill`,
  `Thread#raise`, `Timeout.timeout`, signals and interpreter exit now interrupt a request immediately
  in any phase of the transfer, including DNS resolution and connect, instead of at the next progress tick
* `Session#interrupt` aborts the request in flight from another thread immediately and raises `Patron::Aborted`
* Using one `Session` from two threads at once raises `Patron::Error` instead of corrupting memory
* Response headers and bodies are accumulated directly into Ruby Strings, no more intermediate C buffer and copy
* Multipart requests use libcurl's `curl_mime` API: field values are binary-safe, names and values are copied,
  and multipart `PUT`/`PATCH` work too
* `download_byte_limit` raises `Patron::DownloadLimitExceeded` (a subclass of `Patron::Aborted`)
* Exceptions raised inside a `progress_callback` propagate out of the request after the transfer is cleaned up;
  previously they unwound through libcurl's frames. Returning `false` from the callback aborts the request
* Every `Patron::Error` raised for a transfer carries the libcurl code as `#curl_code`
* A forked child no longer reuses the parent's libcurl handles and connections
* Cookies collected with `handle_cookies` (and TLS sessions) are kept across requests on the same
  `Session`, not only across the redirects of one request
* `enable_debug` accepts an `IO` as well as a path, writes libcurl's verbose output through Ruby, and
  never clobbers the process' stderr

**Memory and VM**

* The `Session` TypedData is write-barrier protected and compaction-aware; the request body is pinned
  only while libcurl reads it; memory size is reported to `ObjectSpace`
* The extension declares itself Ractor-safe: Patron can be used from non-main Ractors
* Statically held exception classes are registered with the GC (they could dangle under compaction before)
* The global list of live sessions, the `at_exit` hook and the bundled `sglib.h` are gone

**Ruby API**

* `Patron::Request` keeps its setters (build one, change the URL, send it again) and also takes keyword
  arguments; any HTTP token is accepted as a verb (#180), verbs libcurl does not know natively are sent as
  custom requests, and `Marshal` now covers every attribute instead of 22 of 31
* `Session.new` takes keyword arguments
* `Response.new` takes keyword arguments (`url:`, `status:`, `redirect_count:`, `header_data:`, `body:`,
  `default_charset:`, `timings:`); a custom `response_class` must accept the same
* `default_response_charset` is now honoured as the fallback for `Response#charset`
* `Response#body` is no longer mutated by `decoded_body`/`inspectable_body`
* `Patron.libcurl_features` reports the runtime libcurl version, TLS backend and feature flags
* `Patron::Request::SSL_VERSIONS` and `HTTP_VERSIONS` list the accepted version names; `"HTTPv3"` is accepted
* `Patron::ProxyType::HTTPS` added
* `base_url` and the request path are joined as URLs, not with `File.join`
* The 0.x positional forms of `Response.new`, `Session.new` and `Session#request` still work in 1.0 with a
  deprecation warning (see `lib/patron/compat.rb` and #209); they go away in 1.1

**Removed**

* `Session#reset` (it was an alias of `interrupt`)
* `ssl_version` values `"SSLv2"` and `"SSLv3"` (refused by every supported libcurl anyway)
* Positional arguments to `Response.new`; `Request::READER_VARS`, `WRITER_VARS` and `VALID_ACTIONS` (see `Request::ATTRIBUTES`)
* Ruby < 3.3, libcurl < 7.81, and the `#if LIBCURL_VERSION_NUM` compatibility branches for libcurl 7.19 through 7.6x

**Build, packaging and tests**

* Require Ruby 3.3 or newer and libcurl 7.81.0 or newer
* Build with pkg-config when available; `--with-curl-dir` now takes precedence over a `curl-config` found on `PATH`
* Remove the dead `patron/proxy_type.rb` file; the `Patron::ProxyType` constants were always defined by the extension
* Stop shipping test fixtures and CI configuration inside the gem
* Test suite: Puma 6 and Rack 3, JSON request readback, configurable ports (`PATRON_TEST_HTTP_PORT` and friends), `PATRON_GC_STRESS=1` for GC and compaction stress runs

### 0.14.0

* Expose libcurl's transfer timings (name lookup, connect, TLS, first byte, total) as `Response#timings`
* Add `ssl_cert`, `ssl_cert_type`, `ssl_key` and `ssl_key_password` for presenting a client certificate (mutual TLS). Thanks @lenage for the original contribution in #165
* Raise `Patron::ClientCertificateError` when the client certificate or its key can't be used
* Accept a `Pathname` for `cacert`
* Fix a request whose options fail to apply (for example an option of the wrong type) leaking its headers and open files into the next request on the same `Session`
* Fix the request body being read from freed memory when `upload_data` is not a String (its `#to_s` result was not kept alive during the transfer)
* Fix multipart field names and values pointing at temporary Strings, and binary multipart values being cut at the first NUL byte
* Fix an exception raised inside `progress_callback` (including `Timeout.timeout` and `Thread#raise`) unwinding through libcurl; it is now re-raised after the transfer is aborted
* Raise `Patron::Error` when a second thread uses a `Session` that is already performing a request, instead of corrupting both requests
* Fix the progress callback being declared with `size_t` arguments where libcurl passes `curl_off_t`
* Accept `download_byte_limit` above 2 GiB, and Floats for `dns_cache_timeout`, `low_speed_time` and `low_speed_limit`
* Fix `Session#unescape` cutting the result at a `%00`, and raise instead of crashing when libcurl fails to escape or unescape
* Reject file paths containing NUL bytes for cookie files, debug output and uploads
* Raise `NoMemoryError` instead of crashing later when libcurl cannot allocate a Session's handles
* Register the exception classes the extension looks up at load time with the GC, so heap compaction (`GC.compact`, `GC.auto_compact`) cannot move them out from under `rb_raise`

### 0.13.4

* Format README a bit better using code fences
* Depend explicitly on base64 for running tests
* Remove C code used for Ruby support below < 2.4 (GVL unlock etc.) and drop support for these versions
* In tests, close Tempfiles before allowing libcurl to use them (cookie jar)
* Fix incorrect ptr type in uses of `curl_easy_escape` / `_unescape`
* Define methods on `Session` as private instance methods from C instead of privatising them from Ruby
* Speed up the /slow endpoint test
* Remove use of `curl_easy_reset`. This should fix the bug with sessions resetting each other's state during `session_free`

### 0.13.3

* Run Puma test servers in separate processes instead of threads

### 0.13.2

* Eagerly initialize libCURL handle when creating the Session instance instead of initializing it lazily
* Remove special treatment of `Session#reset` and make it the same as `Session#interrupt`

### 0.13.0, 0.13.1

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
