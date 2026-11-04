# frozen_string_literal: true

module Patron

  # Represents the response from the HTTP server.
  class Response
    include ResponseHead
    include ResponseDecoding

    # @return [String, nil] the response body as a String encoded as `Encoding::BINARY` or
    #           or `nil` if the response was written directly to a file
    attr_reader :body

    # @return [Hash{Symbol => Float}, nil] curl's cumulative transfer marks in seconds since the request
    #   started: `:namelookup`, `:connect`, `:appconnect`, `:pretransfer`, `:starttransfer`, `:redirect`
    #   and `:total`. `nil` when the response was not built from a curl transfer (e.g. a stub).
    attr_reader :timings

    # Overridden so that the output is shorter and there is no response body printed
    def inspect
      "#<Patron::Response @status_line='#{@status_line}'>"
    end

    # @param url [String] the effective URL after redirects
    # @param status [Integer] the HTTP status code
    # @param redirect_count [Integer] how many redirects were followed
    # @param header_data [String] the raw header lines of every response in the chain, CRLF delimited
    # @param body [String, nil] the response body, or nil when it was downloaded to a file
    # @param default_charset [String, nil] the charset to assume when the Content-Type header names none
    # @param timings [Hash, nil] see #timings
    def initialize(url:, status:, header_data:, redirect_count: 0, body: nil, default_charset: nil, timings: nil)
      @url = url
      @status = status
      @redirect_count = redirect_count
      @body = body && (body.encoding == Encoding::BINARY ? body : body.b)
      @timings = timings

      parse_head(header_data, default_charset)
    end

    # Tells whether the response body can be decoded losslessly into the curren internal encoding
    #
    # @return [Boolean] true if the body is decodable, false if otherwise
    def body_decodable?
      return true if @body.nil?
      return true if decoded_body
    rescue HeaderCharsetInvalid, NonRepresentableBody
      false
    end

    # Returns the response body converted into the Ruby process internal encoding (the one set as `Encoding.default_internal`).
    # As the response gets returned, the response body is not assumed to be in any encoding whatsoever - it will be explicitly
    # set to `Encoding::BINARY` (as if you were reading a file in binary mode).
    #
    # When you call `decoded_body`, the method will
    # look at the `Content-Type` response header, and check if that header specified a charset. If it did, the method will then
    # check whether the specified charset is valid (whether it is possible to find a matching `Encoding` class in the VM).
    # Once that succeeds, the method will check whether the response body _is_ in the encoding that the server said it is.
    #
    # This might not be the case - you can, for instance, easily serve an HTML document with a UTF-8 header (with the header
    # being configured somewhere on the webserver level) and then have the actual HTML document override it with a
    # `meta` element  or `charset` containing an overriding charset. However, parsing the response body is outside of scope for
    # Patron, so if this situation happens (the server sets a charset in the header but this header does not match what the server
    # actually sends in the body) you will get an exception stating this is a problem.
    #
    # The next step is actually converting the body to the internal Ruby encoding. That stage may raise an exception as well, if
    # you are using an internal encoding which can't represent the response body faithfully. For example, if you run Ruby with
    # a CJK internal encoding, and the response you are trying to decode uses Greek characters and is UTF-8, you are going to
    # get an exception since it is impossible to coerce those characters to your internal encoding.
    #
    # @raise {Patron::HeaderCharsetInvalid} when the server supplied a wrong or incorrect charset, {Patron::NonRepresentableBody}
    #    when unable to decode the body into the current process encoding.
    # @return [String, nil]
    def decoded_body
      return unless @body
      return decode_body(true) if frozen? # a shareable Response may not memoize
      @decoded_body ||= decode_body(true)
    end

    # Works the same as `decoded_body`, with one substantial difference: characters which can't be represented
    # in your process' default encoding are going to be replaced with question marks. This can be used for raising
    # errors when you receive responses which indicate errors on the server you are calling. For example, if you expect
    # a binary download, and the server sends you an error message and you don't really want to bother figuring out
    # the encoding it has - but you need to append this response to an error log or similar.
    #
    # @see Patron::Response#decoded_body
    # @return [String, nil]
    def inspectable_body
      return unless @body
      return decode_body(false) if frozen?
      @inspectable_body ||= decode_body(false)
    end
  end
end
