# frozen_string_literal: true

module Patron

  # The response headers, as received. A Hash whose lookups do not care about the case of the
  # header name, since the casing is not ours to predict: HTTP/2 and HTTP/3 send header names
  # lowercase, as does Puma 8 over HTTP/1.1, while most other servers still capitalize them.
  # Per RFC 9110 the name is case-insensitive, so `headers["Content-Length"]` and
  # `headers["content-length"]` find the same header whichever way the server spelled it.
  #
  # The keys stay as they arrived, so iterating, `to_h` and `inspect` show you what was on the
  # wire. Only the lookups are case-insensitive, and only the ones defined here: methods that
  # return a new collection (`select`, `merge`, ...) give you a plain Hash with exact-match
  # lookups, as Hash subclasses do.
  class Headers < Hash
    # @param name [String] the header name, in any case
    # @return [String, Array<String>, nil] the header value, an Array when the header was
    #   received more than once, nil when it was not received at all
    def [](name) = super(key_for(name))

    # The rest of the lookups behave as the Hash ones do, down to the arguments and the
    # exceptions, and differ only in finding a header whose name the server cased differently
    def fetch(name, *default, &block) = super(key_for(name), *default, &block)

    def key?(name) = super(key_for(name))
    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?

    def dig(name, *rest) = super(key_for(name), *rest)

    def values_at(*names) = super(*names.map { |name| key_for(name) })

    def assoc(name) = super(key_for(name))

    def slice(*names) = super(*names.map { |name| key_for(name) })

    def except(*names) = super(*names.map { |name| key_for(name) })

    # Not an endless method, as a setter may not be defined as one
    def []=(name, value)
      super(key_for(name), value)
    end
    alias_method :store, :[]=

    def delete(name, &block) = super(key_for(name), &block)

    private

    # The key as it is actually stored, so that every lookup above can be a plain Hash lookup on
    # it. Headers arrive a couple of dozen at a time, so scanning for a differently cased name
    # costs less than keeping a second index in step would - and it survives freezing
    def key_for(name)
      return name unless name.is_a?(String)
      each_key.find { |key| key.is_a?(String) && key.casecmp?(name) } || name
    end
  end
end
