# -*- encoding: utf-8 -*-
require File.expand_path("../lib/patron/version", __FILE__)

Gem::Specification.new do |s|
  s.name        = "patron"
  s.version     = Patron::VERSION
  s.platform    = Gem::Platform::RUBY
  s.authors     = ["Phillip Toland"]
  s.email       = ["phil.toland@gmail.com"]
  s.homepage    = "https://github.com/toland/patron"
  s.summary     = "Patron HTTP Client"
  s.description = "Ruby HTTP client library based on libcurl"

  s.required_rubygems_version = ">= 1.2.0"
  s.rubyforge_project = "patron"

  s.add_development_dependency "bundler", ">= 1.0.0"
  s.add_development_dependency "rake-compiler", ">= 0.7.5"
  s.add_development_dependency "rspec", ">= 2.3.0"
  s.add_development_dependency "simplecov", "~> 0.12"
  s.add_development_dependency "yard", "~> 0.8"

  s.files        = `git ls-files`.split("\n")
  s.executables  = `git ls-files`.split("\n").map{|f| f =~ /^bin\/(.*)/ ? $1 : nil}.compact
  s.require_paths = ["lib", "ext"]
  s.extensions   = ["ext/patron/extconf.rb"]
  s.post_install_message = %q{
Thank you for installing Patron. On OSX, make sure you are using libCURL with OpenSSL.
SecureTransport-based builds might cause crashes in forking environments.

For more info see https://github.com/curl/curl/issues/788
}
end
