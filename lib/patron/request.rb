
module Patron
  class Request

    def initialize
      @action = :get
      @timeout = 0
      @headers = {}
      @max_redirects = -1
    end

    attr_accessor :url
    attr_reader :action, :timeout, :max_redirects, :headers

    def action=(new_action)
      if ![:get, :put, :post, :delete, :head].include?(new_action)
        raise ArgumentError, "Action must be one of :get, :put, :post, :delete or :head"
      end

      @action = new_action
    end

    def timeout=(new_timeout)
      # TODO add validation
      @timeout = new_timeout
    end

    def max_redirects=(new_max_redirects)
      # TODO add validation
      @max_redirects = new_max_redirects
    end

    def headers=(new_headers)
      # TODO add validation
      @headers = new_headers
    end

  end
end
