require 'rubygems'
require 'yaml'
require 'jeweler'
require 'pathname'

cwd = Pathname(__FILE__).dirname
$:.unshift(cwd) unless $:.include?(cwd) || $:.include?(cwd.expand_path)

require 'patron/session'

module Patron #:nodoc:
  # Returns the version number of the Patron library as a string
  def self.version
    Jeweler::VersionHelper.new(File.dirname(__FILE__) + '/../').to_s
  end
end
