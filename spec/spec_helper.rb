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

$:.unshift(File.dirname(__FILE__) + '/../lib')
$:.unshift(File.dirname(__FILE__) + '/../ext')
require 'patron'

$stderr.puts "Build against #{Patron.libcurl_version}"

Dir['./spec/support/**/*.rb'].each { |fn| require fn }

http_server = Fork.new { PatronTestServer.start(false, 9001) }

sleep 0.1 # Don't interfere the start up output of two processes.

https_server = Fork.new { PatronTestServer.start(true, 9043) }

RSpec.configure do |c|
  c.after(:suite) do
    http_server.kill("TERM")
    https_server.kill("TERM")
    http_server.wait
    https_server.wait
  end
end
