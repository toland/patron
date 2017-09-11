require 'pathname'

cwd = Pathname(__FILE__).dirname
$:.unshift(cwd.to_s) unless $:.include?(cwd.to_s) || $:.include?(cwd.expand_path.to_s)
require 'patron/session'
require 'patron/version'

module Patron
  # Returns the version number of the gem
  # @return [String]
  def self.version
    VERSION
  end
  
  # Returns the default User-Agent string
  # @return [String]
  def self.user_agent_string
    @ua ||= "Patron/Ruby-%s-%s" % [version, libcurl_version]
  end
end
