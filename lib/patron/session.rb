require 'patron/error'
require 'patron/request'
require 'patron/response'
require 'patron/session_ext'


module Patron
  class Session

    attr_accessor :timeout, :max_redirects, :base_url, :headers
    attr_reader :headers

    private :ext_initialize, :handle_request

    def initialize
      ext_initialize
      @timeout = 5
      @headers = {}
      @max_redirects = -1
    end

    def get(url, headers = {})
      req = make_request(:get, url, headers)
      handle_request(req)
    end

  private

    def make_request(action, url, headers)
      r = Request.new
      r.action = action
      r.timeout = self.timeout
      r.max_redirects = self.max_redirects
      r.url = (self.base_url || "") + url
      r.headers = self.headers.merge(headers)
      r
    end

  end
end
