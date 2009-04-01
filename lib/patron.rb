require 'yaml'
require 'pathname'

cwd = Pathname(__FILE__).dirname
$:.unshift(cwd) unless $:.include?(cwd) || $:.include?(cwd.expand_path)

require 'patron/session'

module Patron #:nodoc:
  # Returns the version number of the Patron library as a string
  def self.version
    cwd = Pathname(__FILE__).dirname
    yaml = YAML.load_file(cwd.expand_path / '../VERSION.yml')
    major = (yaml['major'] || yaml[:major]).to_i
    minor = (yaml['minor'] || yaml[:minor]).to_i
    "#{major}.#{minor}"
  end
end
