# frozen_string_literal: true

module Patron

  # What libcurl knows about the connection a response came over, from Response#connection
  # and TransferStats#connection. Frozen.
  #
  # @!attribute [r] http_version
  #   @return [String, nil] "HTTP/1.0", "HTTP/1.1", "HTTP/2" or "HTTP/3"; nil when libcurl did not say
  # @!attribute [r] ip
  #   @return [String, nil] the address of the server the connection went to, as libcurl saw it
  # @!attribute [r] port
  #   @return [Integer] the port on that server
  # @!attribute [r] new_connections
  #   @return [Integer] how many connections libcurl opened for this request; 0 means a cached
  #     connection served it, more than 1 happens with redirects to other hosts
  ConnectionInfo = Data.define(:http_version, :ip, :port, :new_connections) do
    # @return [Boolean] whether a connection the Session already had open served this request
    def reused? = new_connections.zero?

    # @api private
    # @param value [ConnectionInfo, Hash, nil]
    def self.coerce(value)
      case value
      when nil, ConnectionInfo then value
      when Hash then new(**value)
      else raise ArgumentError, "connection must be a Patron::ConnectionInfo, a Hash or nil"
      end
    end
  end
end
