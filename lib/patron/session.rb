require 'patron/error'
require 'patron/request'
require 'patron/response'
require 'patron/session_ext'


module Patron

  # This class represents multiple request/response transactions with an HTTP
  # server.
  class Session

    # HTTP transaction timeout in seconds. Defaults to 5 seconds.
    attr_accessor :timeout

    # Maximum number of times to follow redirects.
    # Set to 0 to disable and -1 to follow all redirects (the default).
    attr_accessor :max_redirects

    # Prepended to the URL in all requests.
    attr_accessor :base_url

    # Standard set of headers that are used in all requests.
    attr_reader :headers

    private :ext_initialize, :handle_request

    # Create an instance of the Session class.
    def initialize
      ext_initialize
      @timeout = 5
      @headers = {}
      @max_redirects = -1
    end

    # Retrieve the contents of the specified +url+ optionally sending the
    # specified headers. If the +base_url+ varaible is set then it is prepended
    # to the +url+ parameter. Any custom headers are merged with the contents
    # of the +headers+ instance variable. The results are returned in a
    # Response object.
    def get(url, headers = {})
      do_request(:get, url, headers)
    end

    # As #get but sends an HTTP HEAD request.
    def head(url, headers = {})
      do_request(:head, url, headers)
    end

    def delete(url, headers = {})
      do_request(:delete, url, headers)
    end

    def put(url, data, headers = {})
      do_request(:put, url, headers, data)
    end

    def post(url, data, headers = {})
      do_request(:post, url, headers, data)
    end

  private

    # Creates a new Request object from the parameters and instance variables.
    def do_request(action, url, headers, data = nil)
      req = Request.new
      req.action = action
      req.timeout = self.timeout
      req.max_redirects = self.max_redirects
      req.headers = self.headers.merge(headers)
      req.upload_data = data

      req.url = self.base_url.to_s + url.to_s
      raise ArgumentError, "Empty URL" if req.url.empty?

      handle_request(req)
    end

  end
end
