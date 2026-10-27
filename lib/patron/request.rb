# frozen_string_literal: true

require 'patron/util'

module Patron

  # Everything needed to perform one HTTP request. Built by Session#build_request, validated
  # and normalized on construction, and immutable from then on. The C extension reads the
  # members through their readers, so a custom Request only has to respond to the same names.
  class Request < Data.define(
    :action, :url, :headers, :timeout, :connect_timeout, :dns_cache_timeout, :max_redirects,
    :username, :password, :auth_type, :proxy, :proxy_type, :insecure, :cacert,
    :ssl_version, :http_version, :ssl_cert, :ssl_cert_type, :ssl_key, :ssl_key_password,
    :ignore_content_length, :buffer_size, :download_byte_limit, :progress_callback,
    :automatic_content_encoding, :force_ipv4, :low_speed_time, :low_speed_limit,
    :upload_data, :file_name, :multipart
  )

    # Any HTTP token works as a verb; the ones libcurl does not know natively are sent as custom requests
    ACTION_RE = /\A[A-Za-z][A-Za-z0-9-]*\z/

    # @param action [Symbol, String] the HTTP verb
    # @param url [String, nil] the complete URL to request
    # @param headers [Hash] request headers
    # @param timeout [Numeric] transfer timeout in seconds, 0 to disable
    # @param connect_timeout [Numeric] connect timeout in seconds, 0 to disable
    # @param max_redirects [Integer] -1 for unlimited, 0 to not follow redirects
    # @param auth_type [Symbol, String, Integer] `:basic`, `:digest`, `:any`, or a `Request::Auth*` constant
    # @param upload_data [Hash, #to_s, #to_path, nil] a Hash is form-encoded (or sent as multipart fields
    #   when `multipart` is set), anything else becomes the request body
    # @param file_name [String, Hash, nil] a file to download into or upload from, or a Hash of multipart file fields
    def initialize(action: :get, url: nil, headers: {}, timeout: 0, connect_timeout: 0, dns_cache_timeout: nil,
                   max_redirects: -1, username: nil, password: nil, auth_type: :basic, proxy: nil, proxy_type: nil,
                   insecure: nil, cacert: nil, ssl_version: nil, http_version: nil, ssl_cert: nil, ssl_cert_type: nil,
                   ssl_key: nil, ssl_key_password: nil, ignore_content_length: nil, buffer_size: nil,
                   download_byte_limit: nil, progress_callback: nil, automatic_content_encoding: nil,
                   force_ipv4: false, low_speed_time: nil, low_speed_limit: nil, upload_data: nil,
                   file_name: nil, multipart: nil)
      action = normalize_action(action)
      super(
        action:,
        url: url&.to_s,
        headers: validate_headers(headers),
        timeout: validate_timeout(timeout),
        connect_timeout: validate_timeout(connect_timeout),
        dns_cache_timeout:,
        max_redirects: validate_max_redirects(max_redirects),
        username:, password:,
        auth_type: normalize_auth_type(auth_type),
        proxy:, proxy_type:, insecure:, cacert:, ssl_version:, http_version:,
        ssl_cert:, ssl_cert_type:, ssl_key:, ssl_key_password:,
        ignore_content_length:,
        buffer_size: validate_buffer_size(buffer_size),
        download_byte_limit:, progress_callback:, automatic_content_encoding:, force_ipv4:,
        low_speed_time:, low_speed_limit:,
        upload_data: normalize_upload_data(upload_data, action, multipart),
        file_name:, multipart:
      )
    end

    # @return [String, nil] the "user:password" pair for HTTP authentication, or nil when either is missing
    def credentials
      return nil if username.nil? || password.nil?
      "#{username}:#{password}"
    end

    # @return [String] the HTTP verb in upper case
    def action_name = action.to_s.upcase

    private

    def normalize_action(action)
      name = action.to_s
      raise ArgumentError, "#{action.inspect} is not a valid HTTP verb" unless name.match?(ACTION_RE)
      name.downcase.to_sym
    end

    def normalize_auth_type(type)
      case type
      in :basic | "basic" then Request::AuthBasic
      in :digest | "digest" then Request::AuthDigest
      in :any | "any" then Request::AuthAny
      in Integer then type
      else raise ArgumentError, "#{type.inspect} is an unknown authentication type"
      end
    end

    def normalize_upload_data(data, action, multipart)
      return data unless data.is_a?(Hash)
      multipart ? data : Util.build_query_string_from_hash(data, action == :post)
    end

    def validate_headers(headers)
      raise ArgumentError, "Headers must be a hash" unless headers.is_a?(Hash)
      headers
    end

    def validate_timeout(seconds)
      return nil if seconds.nil?
      raise ArgumentError, "Timeout must be a positive number" if seconds.to_f < 0
      seconds.to_f
    end

    def validate_max_redirects(count)
      raise ArgumentError, "Max redirects must be a positive integer, 0 or -1" if count.to_i < -1
      count.to_i
    end

    def validate_buffer_size(size)
      return nil if size.nil?
      raise ArgumentError, "Buffer size must be a positive integer greater than 0 or nil" if size.to_i < 1
      size.to_i
    end
  end
end
