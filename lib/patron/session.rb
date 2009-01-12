require 'patron/error'
require 'patron/request'
require 'patron/response'
require 'patron/session_ext'


module Patron
  class Session

    attr_accessor :timeout, :follow_redirects, :headers

    private :ext_initialize, :handle_request

    def initialize
      ext_initialize
    end

    def get(url)
      req = Request.new
      req.url = url
      handle_request(req)
    end

  end
end
