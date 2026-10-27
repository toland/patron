# frozen_string_literal: true

module Patron
  # Contains methods used for decoding the HTTP response body. These are only ever used internally
  # by the Response class.
  module ResponseDecoding

    private

    CHARSET_CONTENT_TYPE_RE = /(?:charset|encoding)="?([a-z0-9-]+)"?/i

    MISREPORTED_ENCODING_ERROR = <<~EOF
      The server stated that the response has the charset matching %{declared}, but the actual
      response body failed to decode as such (not flagged as `valid_encoding?')
      Maybe the response body has a different encoding than suggested by the
      server, or a binary response has been tagged by the server as text by mistake.
      If you are performing requests against servers that are known to report wrong or invalid charsets, use
      `Response#body' instead and handle the character set coercion externally. For instance, you may elect to parse
      the resulting HTML/XML for charset declarations.
    EOF

    INVALID_CHARSET_NAME_ERROR = <<~EOF
      The server specified an invalid charset in the Content-Type header (%{content_type}), \
      or Ruby does not support this charset. If you are performing requests against servers \
      that are known to report wrong or invalid charsets, use 'Response#body` instead \
      and handle the character set coercion at call site.
    EOF

    INTERNAL_CHARSET_MISMATCH_ERROR = <<~EOF
      The response body is %{source_encoding}, but the current \
      `Encoding.default_internal' (or the encoding for a new empty string if you never \
      set `Encoding.default_internal') - %{target_encoding} - cannot be used to represent the response body in \
      a lossless way. Your options are:
      a) using `Response#body' instead
      b) switching your Ruby process to an encoding that supports the needed repertoire
      c) using `Response#inspectable_body' to convert the body in a lossy way
    EOF

    def decode_body(strict)
      body_encoding = encoding_from_headers_or_binary

      # Re-tag a copy, so that #body stays binary no matter what the server claimed
      tagged = @body.dup.force_encoding(body_encoding)
      unless tagged.valid_encoding?
        raise HeaderCharsetInvalid, MISREPORTED_ENCODING_ERROR % { declared: body_encoding }
      end

      if strict
        convert_encoding_and_raise(tagged)
      else
        tagged.encode(internal_encoding, undefined: :replace, replace: '?')
      end
    end

    def convert_encoding_and_raise(str)
      internal = internal_encoding
      str.encode(internal)
    rescue Encoding::UndefinedConversionError
      enc = str.encoding == Encoding::BINARY ? 'binary' : str.encoding.to_s
      raise NonRepresentableBody,
        INTERNAL_CHARSET_MISMATCH_ERROR % { source_encoding: enc, target_encoding: internal }
    end

    def charset_from_content_type
      @headers["Content-Type"].to_s[CHARSET_CONTENT_TYPE_RE, 1]
    end

    def encoding_from_headers_or_binary
      return Encoding::BINARY unless (charset_name = charset_from_content_type)
      Encoding.find(charset_name)
    rescue ArgumentError # invalid charset name
      raise HeaderCharsetInvalid,
            INVALID_CHARSET_NAME_ERROR % { content_type: @headers['Content-Type'].inspect }
    end

    def internal_encoding
      # `Encoding.default_internal` is nil on a stock Ruby while a new empty String is UTF-8,
      # so the String is the better oracle for "what does this process speak"
      Encoding.default_internal || ''.encoding
    end

    def decode_header_data(str)
      # Headers are ISO-8859-1 by the book, but Content-Disposition routinely arrives as raw UTF-8
      # and every browser but localized IE treats it as such, so 8859-1 -> UTF-8 -> binary it is
      [Encoding::ISO8859_1, Encoding::UTF_8, Encoding::BINARY].each do |possible_enc|
        return str.encode(possible_enc)
      rescue ::Encoding::UndefinedConversionError
        next
      end
      str
    end
  end

  private_constant :ResponseDecoding
end
