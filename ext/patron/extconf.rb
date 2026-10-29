# frozen_string_literal: true

require "mkmf"

MIN_LIBCURL = "7.81.0"
MIN_LIBCURL_NUM = 0x075100

# An explicit --with-curl-dir (or -include/-lib) wins over anything on PATH, otherwise
# the SDK's curl-config on macOS silently overrides the Homebrew one the user asked for
explicit_dir = dir_config("curl").any?
unless explicit_dir
  pkg_config("libcurl") ||
    begin
      curl_config = with_config("curl-config") || find_executable("curl-config")
      if curl_config
        $CFLAGS << " " << `#{curl_config} --cflags`.strip
        $LIBS << " " << `#{curl_config} --libs`.strip
      end
    end
end

# pkg-config and curl-config put -lcurl in $LIBS already, so only fall back to have_library
# when linking does not work as-is - otherwise we get -lcurl twice and a linker warning
linked = have_header("curl/curl.h") &&
  (have_func("curl_easy_init", "curl/curl.h") || have_library("curl", "curl_easy_init"))
unless linked
  abort <<~MSG
    Can't find libcurl or curl/curl.h.

    Install the libcurl development package (libcurl4-openssl-dev, curl-dev, ...) or pass
    --with-curl-dir=/path/to/curl (also --with-curl-include / --with-curl-lib,
    or --with-curl-config=/path/to/curl-config) to extconf.
  MSG
end

found_num = try_constant("LIBCURL_VERSION_NUM", "curl/curlver.h")
if found_num.nil? || found_num < MIN_LIBCURL_NUM
  found = found_num ? "%d.%d.%d" % [found_num >> 16, (found_num >> 8) & 0xff, found_num & 0xff] : "an unknown version"
  abort "Patron needs libcurl #{MIN_LIBCURL} or newer, found #{found}."
end

%w[
  CURLOPT_PROTOCOLS_STR
  CURL_HTTP_VERSION_3
  CURLOPT_CA_CACHE_TIMEOUT
  CURL_VERSION_THREADSAFE
  CURLINFO_QUEUE_TIME_T
  CURLINFO_POSTTRANSFER_TIME_T
].each { |const| have_const(const, "curl/curl.h") }
have_func("curl_easy_header", "curl/curl.h")

# Ruby's own warnflags already bring -Wall -Wextra; these two turn the warnings
# that hide real ABI mistakes into errors
append_cflags(%w[-Werror=implicit-function-declaration -Werror=incompatible-pointer-types])
append_cflags("-Werror") if enable_config("werror")

# For sanitizer builds in CI: plain CFLAGS gets clobbered by RbConfig, so use our own names
$CFLAGS << " " << ENV["PATRON_CFLAGS"] if ENV["PATRON_CFLAGS"]
$LDFLAGS << " " << ENV["PATRON_LDFLAGS"] if ENV["PATRON_LDFLAGS"]

create_makefile "patron/session_ext"
