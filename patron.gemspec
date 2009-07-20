# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{patron}
  s.version = "0.4.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Phillip Toland"]
  s.date = %q{2009-07-20}
  s.description = %q{Ruby HTTP client library based on libcurl}
  s.email = %q{phil.toland@gmail.com}
  s.extensions = ["ext/patron/extconf.rb"]
  s.extra_rdoc_files = [
    "README.txt"
  ]
  s.files = [
    "LICENSE",
     "README.txt",
     "Rakefile",
     "ext/patron/extconf.rb",
     "ext/patron/session_ext.c",
     "lib/patron.rb",
     "lib/patron/error.rb",
     "lib/patron/request.rb",
     "lib/patron/response.rb",
     "lib/patron/session.rb",
     "spec/patron_spec.rb",
     "spec/request_spec.rb",
     "spec/response_spec.rb",
     "spec/session_spec.rb",
     "spec/spec.opts",
     "spec/spec_helper.rb"
  ]
  s.has_rdoc = true
  s.homepage = %q{http://github.com/toland/Patron}
  s.rdoc_options = ["--quiet", "--title", "Patron documentation", "--opname", "index.html", "--line-numbers", "--main", "README.txt", "--inline-source"]
  s.require_paths = ["lib", "ext"]
  s.rubyforge_project = %q{patron}
  s.rubygems_version = %q{1.3.2}
  s.summary = %q{Patron HTTP client}
  s.test_files = [
    "spec/patron_spec.rb",
     "spec/request_spec.rb",
     "spec/response_spec.rb",
     "spec/session_spec.rb",
     "spec/spec_helper.rb"
  ]

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 3

    if Gem::Version.new(Gem::RubyGemsVersion) >= Gem::Version.new('1.2.0') then
    else
    end
  else
  end
end
