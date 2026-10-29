# frozen_string_literal: true

module Patron
  module Util
    extend self

    # Flattens a (possibly nested) Hash into "key[sub]=value" pairs, Rack style
    def build_query_pairs_from_hash(hash, escape_values = false, prefix = nil, pairs = [])
      hash.each_pair do |k, v|
        key = prefix ? "#{prefix}[#{k}]" : k.to_s
        if v.is_a?(Hash)
          build_query_pairs_from_hash(v, escape_values, key, pairs)
        else
          v = Patron::Session.escape(v.to_s) if escape_values
          pairs << "#{key}=#{v}"
        end
      end
      pairs
    end

    def build_query_string_from_hash(hash, escape_values = false)
      build_query_pairs_from_hash(hash, escape_values).join('&')
    end
  end
end
