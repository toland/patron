# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = %q{patron}
  s.version = "0.3.1"

  s.required_rubygems_version = Gem::Requirement.new(">= 0") if s.respond_to? :required_rubygems_version=
  s.authors = ["Phillip Toland"]
  s.date = %q{2009-04-01}
  s.description = %q{Ruby HTTP client library based on libcurl}
  s.email = %q{ptoland@thehive.com}
  s.extensions = ["ext/patron/extconf.rb"]
  s.extra_rdoc_files = ["README.txt"]
  s.files = ["README.txt", "Rakefile", "lib/patron", "lib/patron/error.rb", "lib/patron/request.rb", "lib/patron/response.rb", "lib/patron/session.rb", "lib/patron.rb", "spec/patron_spec.rb", "spec/request_spec.rb", "spec/session_spec.rb", "spec/spec.opts", "spec/spec_helper.rb", "ext/patron/extconf.rb", "ext/patron/session_ext.c"]
  s.has_rdoc = true
  s.homepage = %q{http://www.thehive.com/}
  s.rdoc_options = ["--quiet", "--title", "Patron documentation", "--opname", "index.html", "--line-numbers", "--main", "README.txt", "--inline-source", "--inline-source", "--charset=UTF-8"]
  s.require_paths = ["lib", "ext"]
  s.rubyforge_project = %q{patron}
  s.rubygems_version = %q{1.3.1}
  s.summary = %q{Ruby HTTP client library based on libcurl}

  if s.respond_to? :specification_version then
    current_version = Gem::Specification::CURRENT_SPECIFICATION_VERSION
    s.specification_version = 2

    if Gem::Version.new(Gem::RubyGemsVersion) >= Gem::Version.new('1.2.0') then
      s.add_runtime_dependency(%q<technicalpickles-jeweler>, [">= 0.6.5"])
    else
      s.add_dependency(%q<technicalpickles-jeweler>, [">= 0.6.5"])
    end
  else
    s.add_dependency(%q<technicalpickles-jeweler>, [">= 0.6.5"])
  end
end
