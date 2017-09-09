require 'rake/clean'
require 'rake/extensiontask'
require 'rspec/core/rake_task'
require "bundler/gem_tasks"
require 'yard'

RSpec::Core::RakeTask.new(:spec)

Rake::ExtensionTask.new do |ext|
  ext.name = 'session_ext'           # indicate the name of the extension.
  ext.ext_dir = 'ext/patron'         # search for 'hello_world' inside it.
  ext.lib_dir = 'lib/patron'         # put binaries into this folder.
end

CLEAN.include FileList["ext/patron/*"].exclude(/^.*\.(rb|c|h)$/)
CLOBBER.include %w( doc coverage pkg )

desc "Start an IRB shell"
task :shell => :compile do
  sh 'irb -I./lib -I./ext -r patron'
end

desc "Generate YARD documentation"
YARD::Rake::YardocTask.new do |t|
  t.files   = ['lib/**/*.rb', 'ext/**/*.c' ]
  t.options = ['--markup markdown']
  t.stats_options = ['--list-undoc']
end

task :default => [:clobber, :compile, :spec]
task :build => [:clobber] # Make sure no binaries end up in the gem
