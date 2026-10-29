# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "patron/version"

Gem::Specification.new do |spec|
  spec.name        = "patron"
  spec.version     = Patron::VERSION
  spec.licenses    = ["MIT"]
  spec.authors     = ["Aeryn Riley Dowling-Toland", "Julik Tarkhanov"]
  spec.email       = ["aeryn.toland@gmail.com", "me@julik.nl"]
  spec.homepage    = "https://github.com/toland/patron"
  spec.summary     = "Patron HTTP Client"
  spec.description = "Ruby HTTP client library based on libcurl"

  spec.metadata = {
    "source_code_uri" => "https://github.com/toland/patron",
    "changelog_uri" => "https://github.com/toland/patron/blob/master/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/toland/patron/issues",
    "rubygems_mfa_required" => "true"
  }

  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir["lib/**/*.rb", "ext/**/*.{c,h,rb}"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/patron/extconf.rb"]
end
