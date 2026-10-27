# frozen_string_literal: true

# The positional-argument forms of the 0.x API, kept for the 1.0 line so that webmock's
# adapter and sniffer's wrapper keep working while they move to keywords. Each form warns
# once. Everything about this lives here on purpose: to drop it in 1.1, delete this file,
# its require in session.rb and spec/compat_spec.rb. See https://github.com/toland/patron/issues/209
module Patron
  module Compat
    @warned = {}

    # uplevel counts frames up to the user's call site: deprecated -> shim method -> caller
    def self.deprecated(form, replacement, uplevel: 2)
      return if @warned[form]
      @warned[form] = true
      warn "Patron: #{form} is deprecated and will be removed in Patron 1.1, use #{replacement} instead (https://github.com/toland/patron/issues/209)", uplevel: uplevel
    end

    # Session.new(hash) and request(action, url, headers, options_hash)
    module SessionArguments
      def initialize(*positional, **options, &block)
        options = Compat.hash_to_keywords("Patron::Session.new with a Hash", positional, options)
        super(**options, &block)
      end

      def request(action, url, headers = {}, *positional, **options)
        options = Compat.hash_to_keywords("Patron::Session#request with an options Hash", positional, options)
        super(action, url, headers, **options)
      end
    end

    # Response.new(url, status, redirect_count, header_data, body, default_charset = nil)
    module ResponseArguments
      POSITIONAL = %i[url status redirect_count header_data body default_charset].freeze

      def new(*positional, **keywords)
        return super(**keywords) if positional.empty?

        Compat.deprecated("Patron::Response.new with positional arguments", "keyword arguments")
        if positional.size > POSITIONAL.size
          raise ArgumentError, "wrong number of arguments (given #{positional.size}, expected 5..6)"
        end
        super(**POSITIONAL.zip(positional).to_h.compact, **keywords)
      end
    end

    def self.hash_to_keywords(form, positional, keywords)
      return keywords if positional.empty?
      unless positional.size == 1 && positional.first.is_a?(Hash)
        raise ArgumentError, "wrong number of arguments (given #{positional.size}, expected 0)"
      end

      deprecated(form, "keyword arguments", uplevel: 3)
      positional.first.transform_keys(&:to_sym).merge(keywords)
    end
  end

  Session.prepend(Compat::SessionArguments)
  Response.singleton_class.prepend(Compat::ResponseArguments)
end
