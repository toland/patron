# frozen_string_literal: true

require 'patron/version'
require 'patron/session'

module Patron
  # @return [String] the version of the gem
  def self.version = VERSION

  # @return [String] the default User-Agent header value
  def self.user_agent_string = USER_AGENT_STRING

  USER_AGENT_STRING = "Patron/Ruby-#{VERSION}-#{libcurl_version}".freeze
end
