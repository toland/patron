# frozen_string_literal: true

if ENV["COVERAGE"]
  require 'simplecov'
  SimpleCov.start do
    add_filter "/spec/"
  end
end
require 'rspec'
require 'socket'

# Kill warnings that not raising a specific exception still allows the method
# to fail with another exception
RSpec::Expectations.configuration.warn_about_potential_false_positives = false

require 'patron'

$stderr.puts "Build against #{Patron.libcurl_version}"

Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |fn| require fn }

# Overridable so that several checkouts can run their suites side by side
HTTP_PORT = Integer(ENV.fetch('PATRON_TEST_HTTP_PORT', 9001))
HTTPS_PORT = Integer(ENV.fetch('PATRON_TEST_HTTPS_PORT', 9043))
MTLS_PORT = Integer(ENV.fetch('PATRON_TEST_MTLS_PORT', 9044))

http_server = Fork.new { PatronTestServer.start(false, HTTP_PORT) }
https_server = Fork.new { PatronTestServer.start(true, HTTPS_PORT) }
mtls_server = Fork.new do
  PatronTestServer.start(true, MTLS_PORT, client_ca: File.join(__dir__, 'support', 'certs', 'client_ca.pem'))
end

def wait_for_port(port, timeout: 15)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    TCPSocket.new('127.0.0.1', port).close
    return
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET
    raise "Test server on port #{port} did not come up in #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.05
  end
end

[HTTP_PORT, HTTPS_PORT, MTLS_PORT].each { |port| wait_for_port(port) }

RSpec.configure do |c|
  c.after(:suite) do
    [http_server, https_server, mtls_server].each { |s| s.kill("TERM") }
    [http_server, https_server, mtls_server].each(&:wait)
  end
end
