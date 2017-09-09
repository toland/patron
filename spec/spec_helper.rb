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

PatronTestServer.start(nil, false, 9001) if RUBY_VERSION >= '1.9'
PatronTestServer.start(nil, true, 9043) if RUBY_VERSION >= '1.9'
