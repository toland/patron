require 'mkmf'
require 'rbconfig'

if find_executable('curl-config')
  $CFLAGS << " #{`curl-config --cflags`.strip}"
  $LIBS << " #{`curl-config --libs`.strip}"
elsif !have_library('curl') or !have_header('curl/curl.h')
  fail <<-EOM
  Can't find libcurl or curl/curl.h

  Try passing --with-curl-dir or --with-curl-lib and --with-curl-include
  options to extconf.
  EOM
end

if CONFIG['CC'] =~ /gcc/
  $CFLAGS << ' -Wall'
end

create_makefile 'patron/session_ext'
