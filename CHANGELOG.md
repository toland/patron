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
