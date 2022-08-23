require 'mkmf'
require 'rbconfig'

dir_config('curl')
curl_config_path = with_config('curl-config') || find_executable('curl-config')
if curl_config_path
  $CFLAGS << " " << `#{curl_config_path} --cflags`.strip
  $LIBS << " " << `#{curl_config_path} --libs`.strip
elsif !have_library('curl') or !have_header('curl/curl.h')
  fail <<-EOM
  Can't find libcurl or curl/curl.h

  Try passing --with-curl-config, --with-curl-dir, or --with-curl-lib and --with-curl-include
  options to extconf.
  EOM
end

if CONFIG['CC'] =~ /gcc/
  $CFLAGS << ' -pedantic -Wall'
end

if CONFIG['CC'] =~ /clang/
  $CFLAGS << ' -pedantic -Wall -Wno-void-pointer-to-enum-cast'
end

create_makefile 'patron/session_ext'
