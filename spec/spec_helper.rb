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

http_server_pid = Process.fork { PatronTestServer.start(false, 9001) }
https_server_pid = Process.fork { PatronTestServer.start(true, 9043) }

RSpec.configure do |c|
  c.after(:suite) do
    Process.kill("INT", http_server_pid)
    Process.kill("INT", https_server_pid)
    Process.wait(http_server_pid)
    Process.wait(https_server_pid)
  end
end