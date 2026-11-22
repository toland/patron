# frozen_string_literal: true

module Patron

  # The response headers, as received. A Hash whose lookups do not care about the case of the
  # header name, since the casing is not ours to predict: HTTP/2 and HTTP/3 send header names
  # lowercase, as does Puma 8 over HTTP/1.1, while most other servers still capitalize them.
  # Per RFC 9110 the name is case-insensitive, so `headers["Content-Length"]` and
  # `headers["content-length"]` find the same header whichever way the server spelled it.
  #
  # The keys stay as they arrived, because the casing can be data rather than noise: a signing
  # scheme that covers headers signs the names it was given, so casefolding them once would
  # shadow what the server actually sent. Iterating, `keys`, `to_h` and `inspect` all show you
  # the wire.
  #
  # Only one header of a given name is kept, whatever the casing: writing "content-type" over a
  # "Content-Type" that is already there replaces the value and leaves the key as it was. Methods
  # that build a new collection out of this one (`merge`, `select`, `slice`, `transform_values`
  # and the like) give back another Headers with that same invariant, rather than the plain Hash
  # a Hash subclass gets by default.
  #
  # Two things to know about the edges. `to_h` hands you a plain Hash on purpose, as the way out
  # of all of this. And C code that reads a Hash through `rb_hash_aref` does not dispatch to the
  # `#[]` below at all - which is why every write path here is overridden rather than left to
  # Hash, since `Hash#merge` writing through C is what would leave a second casing of a header
  # behind. Of the readers in core only `String#%` and `format` work that way, and those look up
  # Symbols, so a header name never reaches them to begin with.
  class Headers < Hash
    # Builds Headers the way `Hash[]` builds a Hash, except that names differing only in case
    # collapse into the first of them, with the last value
    #
    # @return [Patron::Headers]
    def self.[](*args)
      super.each_with_object(new) { |(name, value), headers| headers.store(name, value) }
    end

    # @param name [String] the header name, in any case
    # @return [String, Array<String>, nil] the header value, an Array when the header was
    #   received more than once, nil when it was not received at all
    def [](name) = super(key_for(name))

    # The other lookups behave as the Hash ones do, down to the arguments and the exceptions,
    # and differ only in finding a header whose name the server cased differently
    def fetch(name, *default, &block) = super(key_for(name), *default, &block)

    def fetch_values(*names, &block) = super(*names.map { |name| key_for(name) }, &block)

    def key?(name) = super(key_for(name))
    alias_method :has_key?, :key?
    alias_method :include?, :key?
    alias_method :member?, :key?

    def dig(name, *rest) = super(key_for(name), *rest)

    def values_at(*names) = super(*names.map { |name| key_for(name) })

    def assoc(name) = super(key_for(name))

    def to_proc = ->(name) { self[name] }

    # Writing a name that is already there under another casing replaces that header rather than
    # adding a second one. Not an endless method, as a setter may not be defined as one
    def []=(name, value)
      super(key_for(name), value)
    end
    alias_method :store, :[]=

    def delete(name, &block) = super(key_for(name), &block)

    # Hash gives a subclass a plain Hash back from everything that builds a new collection, and
    # a plain Hash looks its keys up by the exact name again. These keep the type, so that one
    # case-insensitive Headers does not quietly become a case-sensitive Hash halfway through
    def select(&block) = self.class[super]
    alias_method :filter, :select

    def reject(&block) = self.class[super]

    def compact = self.class[super]

    def invert = self.class[super]

    def transform_values(&block) = self.class[super]

    def transform_keys(...) = self.class[super]

    def transform_keys!(...) = replace(to_h.transform_keys(...))

    def slice(*names) = self.class[super(*names.map { |name| key_for(name) })]

    def except(*names) = self.class[super(*names.map { |name| key_for(name) })]

    # Hash#merge and Hash#update write through C, which never reaches #[]= above, so a hash
    # carrying "content-type" merged over a "Content-Type" would leave both of them behind and
    # the stale one in front. These go pair by pair instead
    def merge(*others, &block) = dup.merge!(*others, &block)

    def merge!(*others)
      others.each do |other|
        other.to_hash.each_pair do |name, value|
          key = key_for(name)
          value = yield(key, self[key], value) if block_given? && key?(key)
          store(key, value)
        end
      end
      self
    end
    alias_method :update, :merge!

    def replace(other)
      clear
      merge!(other)
    end

    # Comparing keys by identity cannot be squared with finding a header by a name the server
    # cased differently, so this is refused rather than half-honoured
    def compare_by_identity
      raise TypeError, "Patron::Headers looks its keys up by name, so it cannot compare them by identity"
    end

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
