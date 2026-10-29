# frozen_string_literal: true

require 'patron/util'

module Patron

  # Represents the information necessary for an HTTP request. A data object with
  # validation in the setters, built by Session#build_request or by hand. A Request
  # can be reused: the extension reads its attributes once when the request starts,
  # so changing the URL and sending it again is fine.
  class Request
    ATTRIBUTES = %i[
      action url headers timeout connect_timeout dns_cache_timeout max_redirects
      username password auth_type proxy proxy_type insecure cacert
      ssl_version http_version ssl_cert ssl_cert_type ssl_key ssl_key_password
      ignore_content_length buffer_size download_byte_limit progress_callback
      automatic_content_encoding force_ipv4 low_speed_time low_speed_limit
      upload_data file_name multipart
    ].freeze

    # Any HTTP token works as a verb; the ones libcurl does not know natively are sent as custom requests
    ACTION_RE = /\A[A-Za-z][A-Za-z0-9-]*\z/

    # Attributes without validation of their own
    attr_accessor :url, :username, :password, :file_name, :proxy, :proxy_type, :insecure, :dns_cache_timeout,
                  :ignore_content_length, :multipart, :cacert, :ssl_version, :http_version,
                  :automatic_content_encoding, :force_ipv4, :download_byte_limit, :low_speed_time,
                  :low_speed_limit, :progress_callback, :ssl_cert, :ssl_cert_type, :ssl_key, :ssl_key_password

    attr_reader :action, :headers, :timeout, :connect_timeout, :max_redirects, :auth_type, :buffer_size, :upload_data

    # Defaults to a GET with no timeouts and unlimited redirects. Attributes may be given as
    # keywords; `action` and `multipart` are applied first since `upload_data=` depends on them.
    #
    # @param attributes [Hash] attribute values by name
    def initialize(**attributes)
      @action = :get
      @headers = {}
      @timeout = 0.0
      @connect_timeout = 0.0
      @max_redirects = -1
      @auth_type = Request::AuthBasic
      @force_ipv4 = false

      unknown = attributes.keys - ATTRIBUTES
      raise ArgumentError, "Unknown Request attributes: #{unknown.join(', ')}" unless unknown.empty?

      %i[action multipart].each { |first| public_send("#{first}=", attributes[first]) if attributes.key?(first) }
      attributes.each { |name, value| public_send("#{name}=", value) unless %i[action multipart].include?(name) }
    end

    # Set the type of authentication to use for this request.
    #
    # @param type [String, Symbol, Integer] `:basic`, `:digest`, `:any`, or a `Request::Auth*` constant
    def auth_type=(type)
      @auth_type = case type
      in :basic | "basic" | nil then Request::AuthBasic
      in :digest | "digest" then Request::AuthDigest
      in :any | "any" then Request::AuthAny
      in Integer then type
      else raise ArgumentError, "#{type.inspect} is an unknown authentication type"
      end
    end

    # Sets the request body. A Hash is form-encoded, unless the request is multipart, in which
    # case libcurl composes the body from it. Anything else is sent as its `to_s`, or uploaded
    # from the file it names when it responds to `to_path`.
    #
    # @param data [Hash, #to_s, #to_path, nil]
    def upload_data=(data)
      @upload_data = if data.is_a?(Hash) && !multipart
        Util.build_query_string_from_hash(data, action == :post)
      else
        data
      end
    end

    # Sets the HTTP verb. Any HTTP token is accepted (#180); the ones libcurl does not know
    # natively are sent as custom requests.
    #
    # @param action [Symbol, String]
    def action=(action)
      name = action.to_s
      raise ArgumentError, "#{action.inspect} is not a valid HTTP verb" unless name.match?(ACTION_RE)
      @action = name.downcase.to_sym
    end

    # @param seconds [Numeric, nil] transfer timeout, fractional seconds allowed, 0 or nil to disable
    def timeout=(seconds)
      @timeout = validate_timeout(seconds)
    end

    # @param seconds [Numeric, nil] connect timeout, fractional seconds allowed, 0 or nil to disable
    def connect_timeout=(seconds)
      @connect_timeout = validate_timeout(seconds)
    end

    # @param count [Integer] -1 for unlimited, 0 to not follow redirects
    def max_redirects=(count)
      raise ArgumentError, "Max redirects must be a positive integer, 0 or -1" if count.to_i < -1
      @max_redirects = count.to_i
    end

    # @param new_headers [Hash] replaces the headers set so far
    def headers=(new_headers)
      raise ArgumentError, "Headers must be a hash" unless new_headers.is_a?(Hash)
      @headers = new_headers
    end

    # @param size [Integer, nil] the receive buffer size libcurl should use, nil for its default
    def buffer_size=(size)
      raise ArgumentError, "Buffer size must be a positive integer greater than 0 or nil" if !size.nil? && size.to_i < 1
      @buffer_size = size&.to_i
    end

    # @return [String, nil] the "user:password" pair for HTTP authentication, or nil when either is missing
    def credentials
      return nil if username.nil? || password.nil?
      "#{username}:#{password}"
    end

    # @return [String] the HTTP verb in upper case
    def action_name = action.to_s.upcase

    # @return [Hash{Symbol => Object}] every attribute by name
    def to_h = ATTRIBUTES.to_h { |name| [name, public_send(name)] }

    # @return [Boolean] whether the other request is configured identically
    def eql?(other)
      other.is_a?(Request) && to_h == other.to_h
    end
    alias == eql?

    def hash = to_h.hash

    # @return [Hash] every attribute, so that Marshal round-trips are complete
    def marshal_dump = to_h

    # @param attributes [Hash]
    def marshal_load(attributes)
      initialize(**attributes.compact.except(:progress_callback))
      @progress_callback = attributes[:progress_callback]
    end

    private

    def validate_timeout(seconds)
      return nil if seconds.nil?
      raise ArgumentError, "Timeout must be a positive number" if seconds.to_f < 0
      seconds.to_f
    end
  end
end
