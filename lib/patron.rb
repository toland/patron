require 'pathname'

cwd = Pathname(__FILE__).dirname
$:.unshift(cwd) unless $:.include?(cwd) || $:.include?(cwd.expand_path)

require 'patron/version'
require 'patron/session'

module Patron #:nodoc:
  # Returns the version number of the Patron library as a string
  def self.version
    Patron::VERSION::STRING
  end
end
