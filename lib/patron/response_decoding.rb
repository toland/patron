module Patron
  # Contains methods used for decoding the HTTP response body. These are only ever used internally
  # by the Response class.
  module ResponseDecoding
    
    private

    CHARSET_CONTENT_TYPE_RE = /(?:charset|encoding)="?([a-z0-9-]+)"?/i.freeze
    
    MISREPORTED_ENCODING_ERROR = <<-EOF
The server stated that the response has the charset matching %{declared}, but the actual
response body failed to decode as such (not flagged as `valid_encoding?')
Maybe the response body has a different encoding than suggested by the
server, or a binary response has been tagged by the server as text by mistake.
If you are performing requests against servers that are known to report wrong or invalid charsets, use
`Response#body' instead and handle the character set coercion externally. For instance, you may elect to parse
the resulting HTML/XML for charset declarations.
EOF
  
    INVALID_CHARSET_NAME_ERROR = <<-EOF
The server specified an invalid charset in the Content-Type header (%{content_type}), \
or Ruby does not support this charset. If you are performing requests against servers \
that are known to report wrong or invalid charsets, use 'Response#body` instead \
and handle the character set coercion at call site.
EOF
    
    INTERNAL_CHARSET_MISMATCH_ERROR = <<-EOF
The response body is %{source_encoding}, but the current \
`Encoding.default_internal' (or the encoding for a new empty string if you never \
set `Encoding.default_internal') - %{target_encoding} - cannot be used to represent the response body in \
a lossless way. Your options are:
a) using `Response#body' instead
b) switching your Ruby process to an encoding that supports the needed repertoire
c) using `Response#inspectable_body' to convert the body in a lossy way
EOF

    def decode_body(strict)
      # Try to detect the body encoding from headers
      body_encoding = encoding_from_headers_or_binary
  
      # See if the body actually _is_ in this encoding. 
      encoding_matched = @body.force_encoding(body_encoding).valid_encoding?
      if !encoding_matched
        raise HeaderCharsetInvalid,  MISREPORTED_ENCODING_ERROR % {declared: body_encoding}
      end
  
      if strict
        convert_encoding_and_raise(@body)
      else
        @body.encode(internal_encoding, :undefined => :replace, :replace => '?')
      end
    end

    def convert_encoding_and_raise(str)
      internal = internal_encoding
      str.encode(internal)
    rescue Encoding::UndefinedConversionError => e
      enc = str.encoding == Encoding::BINARY ? 'binary' : str.encoding.to_s
      raise NonRepresentableBody,
        INTERNAL_CHARSET_MISMATCH_ERROR % {source_encoding: enc, target_encoding: internal}
    end
    
    def charset_from_content_type
      return $1 if @headers["Content-Type"].to_s =~ CHARSET_CONTENT_TYPE_RE
    end
    
    def encoding_from_headers_or_binary
      return Encoding::BINARY unless charset_name = charset_from_content_type
      Encoding.find(charset_name)
    rescue ArgumentError => e # invalid charset name
      raise HeaderCharsetInvalid,
            INVALID_CHARSET_NAME_ERROR % {content_type: @headers['Content-Type'].inspect}
    end
    
    def internal_encoding
      # Use a trick here - instead of using `default_internal` we will create
      # an empty string, and then get it's encoding instead. For example, this holds
      # true on 2.1+ on OSX:
      #
      #     Encoding.default_internal #=> nil
      #     ''.encoding #=> #<Encoding:UTF-8>
      Encoding.default_internal || ''.encoding
    end
    
    def decode_header_data(str)
      # Header data is tricky. Strictly speaking, it _must_ be ISO-encoded. However, Content-Disposition
      # sometimes gets sent as raw UTF8 - and most browsers (except for localized IE versions on Windows)
      # treat it as such. So a fallback chain of 8859-1->UTF8->binary seems the most sane.
      tries = [Encoding::ISO8859_1, Encoding::UTF_8, Encoding::BINARY]
      tries.each do |possible_enc|
        begin
          return str.encode(possible_enc)
        rescue ::Encoding::UndefinedConversionError
          next
        end
      end
      str # if it doesn't encode, just give back what we got
    end
  end
  
  private_constant :ResponseDecoding if respond_to?(:private_constant)
end
