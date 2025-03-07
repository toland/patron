# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'patron/version'

Gem::Specification.new do |spec|
  spec.name        = "patron"
  spec.version     = Patron::VERSION
  spec.licenses    = ["MIT"]
  spec.platform    = Gem::Platform::RUBY
  spec.authors     = ["Aeryn Riley Dowling-Toland"]
  spec.email       = ["aeryn.toland@gmail.com"]
  spec.homepage    = "https://github.com/toland/patron"
  spec.summary     = "Patron HTTP Client"
  spec.description = "Ruby HTTP client library based on libcurl"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "https://rubygems.org"
  else
    raise "RubyGems 2.0 or newer is required to protect against public gem pushes."
  end

  spec.required_rubygems_version = ">= 1.2.0"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib", "ext"]
  spec.extensions   = ["ext/patron/extconf.rb"]
  spec.post_install_message = %q{
Thank you for installing Patron. On OSX, make sure you are using libCURL with OpenSSL.
SecureTransport-based builds might cause crashes in forking environments.

For more info see https://github.com/curl/curl/issues/788
}
end
