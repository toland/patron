
module Patron

  # Represents the response from the HTTP server.
  class Response

    attr_reader :url, :status, :redirect_count, :body, :headers

  end
end
