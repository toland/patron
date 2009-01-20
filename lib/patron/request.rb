
module Patron

  # Represents the information necessary for an HTTP request.
  # This is basically a data object with validation. Not all fields will be
  # used in every request.
  class Request

    def initialize
      @action = :get
      @timeout = 0
      @headers = {}
      @max_redirects = -1
    end

    attr_accessor :url, :upload_data
    attr_reader :action, :timeout, :max_redirects, :headers

    def action=(new_action)
      if ![:get, :put, :post, :delete, :head].include?(new_action)
        raise ArgumentError, "Action must be one of :get, :put, :post, :delete or :head"
      end

      @action = new_action
    end

    def timeout=(new_timeout)
      if new_timeout.to_i < 1
        raise ArgumentError, "Timeout must be a positive integer greater than 0"
      end

      @timeout = new_timeout.to_i
    end

    def max_redirects=(new_max_redirects)
      if new_max_redirects.to_i < -1
        raise ArgumentError, "Max redirects must be a positive integer, 0 or -1"
      end

      @max_redirects = new_max_redirects.to_i
    end

    def headers=(new_headers)
      if !new_headers.kind_of?(Hash)
        raise ArgumentError, "Headers must be a hash"
      end

      @headers = new_headers
    end

  end
end
