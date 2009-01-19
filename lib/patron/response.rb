
module Patron

  # Represents the response from the HTTP server.
  class Response

    attr_reader :url, :status, :body, :headers, :reason, :version, :cookies

  end
end
