require 'yaml'
require 'rake/clean'
require 'rake/rdoctask'
require 'spec/rake/spectask'
require 'jeweler'

require 'rbconfig'
include Config

EXT_DIR     = 'ext/patron'
SESSION_SO  = "#{EXT_DIR}/session_ext.#{CONFIG['DLEXT']}"
SESSION_SRC = "#{EXT_DIR}/session_ext.c"

CLEAN.include FileList["#{EXT_DIR}/*"].exclude(/^.*\.(rb|c)$/)
CLOBBER.include %w( doc coverage pkg )

Jeweler::Tasks.new do |s|
  s.name              = 'patron'
  s.platform          = Gem::Platform::RUBY
  s.author            = 'Phillip Toland'
  s.email             = 'ptoland@thehive.com'
  s.homepage          = 'http://www.thehive.com/'
  s.rubyforge_project = 'patron'
  s.summary           = 'Ruby HTTP client library based on libcurl'
  s.description       = s.summary

  s.extensions    << 'ext/patron/extconf.rb'
  s.require_paths << 'ext'

  s.files = FileList['README.txt',
                     'Rakefile',
                     'lib/**/*',
                     'spec/*',
                     'ext/patron/*.{rb,c}']

  # rdoc
  s.has_rdoc         = true
  s.extra_rdoc_files = ['README.txt']
  s.rdoc_options     = ['--quiet',
                        '--title', "Patron documentation",
                        '--opname', 'index.html',
                        '--line-numbers',
                        '--main', 'README.txt',
                        '--inline-source']

  # Dependencies
  s.add_dependency 'technicalpickles-jeweler', '>= 0.6.5'
end

file SESSION_SO => SESSION_SRC do
  cd EXT_DIR do
    ruby 'extconf.rb'
    sh 'make'
  end
end

desc "Compile extension"
task :compile => SESSION_SO

desc "Start an IRB shell"
task :shell => :compile do
  sh 'irb -I./lib -I./ext -r patron'
end

Rake::RDocTask.new do |rdoc|
  rdoc.rdoc_dir = 'doc'
  rdoc.title = "Patron documentation"
  rdoc.main = 'README.txt'
  rdoc.options << '--line-numbers' << '--inline-source'
  rdoc.rdoc_files.include('README.txt')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

desc "Run specs"
Spec::Rake::SpecTask.new(:spec) do |t|
  t.spec_opts = ['--options', "spec/spec.opts"]
  t.spec_files = FileList['spec/**/*_spec.rb']
end

task :spec => [:compile]

desc "Run specs with RCov"
Spec::Rake::SpecTask.new('spec:rcov') do |t|
  t.spec_files = FileList['spec/**/*_spec.rb']
  t.rcov = true
  t.rcov_opts << '--sort coverage'
  t.rcov_opts << '--comments'
  t.rcov_opts << '--exclude spec'
  t.rcov_opts << '--exclude lib/magneto.rb'
  t.rcov_opts << '--exclude /Library/Ruby/Gems'
end

task :default => :spec
