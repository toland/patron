# frozen_string_literal: true

if ENV["COVERAGE"]
  require 'simplecov'
  SimpleCov.start do
    add_filter "/spec/"
  end
end
require 'rspec'

# Kill warnings that not raising a specific exception still allows the method
# to fail with another exception
RSpec::Expectations.configuration.warn_about_potential_false_positives = false

require 'patron'

$stderr.puts "Build against #{Patron.libcurl_version}"

Dir[File.join(__dir__, 'support', '**', '*.rb')].sort.each { |fn| require fn }

http_server = Fork.new { PatronTestServer.start(false, 9001) }

sleep 0.1 # Don't interfere the start up output of two processes.

https_server = Fork.new { PatronTestServer.start(true, 9043) }

mtls_server = Fork.new do
  PatronTestServer.start(true, 9044, client_ca: File.join(__dir__, 'support', 'certs', 'client_ca.pem'))
end

RSpec.configure do |c|
  c.after(:suite) do
    http_server.kill("TERM")
    https_server.kill("TERM")
    mtls_server.kill("TERM")
    http_server.wait
    https_server.wait
    mtls_server.wait
  end
end
