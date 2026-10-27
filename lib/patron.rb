# frozen_string_literal: true

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
