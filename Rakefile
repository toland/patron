## -------------------------------------------------------------------
##
## Copyright (c) 2008 The Hive http://www.thehive.com/
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
## THE SOFTWARE.
##
## -------------------------------------------------------------------
require 'rake/clean'
require 'rake/extensiontask'
require 'rspec/core/rake_task'
require 'bundler'
require 'yard'

Rake::ExtensionTask.new do |ext|
  ext.name = 'session_ext'           # indicate the name of the extension.
  ext.ext_dir = 'ext/patron'         # search for 'hello_world' inside it.
  ext.lib_dir = 'lib/patron'         # put binaries into this folder.
end

Bundler::GemHelper.install_tasks

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

desc "Run specs"
RSpec::Core::RakeTask.new do |t|
  t.rspec_opts = %w( --colour --format progress )
  t.pattern = 'spec/**/*_spec.rb'
end

task :spec => [:compile]

task :default => :spec
