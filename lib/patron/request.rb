
module Patron
  class Request

    def initialize
      @action = :get
      @timeout = 5
      @max_redirects = 0
    end

    attr_accessor :action, :url, :timeout, :max_redirects

  end
end
