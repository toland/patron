module Patron
  module Util
    extend self
    
    def build_query_pairs_from_hash(hash, escape_values=false)
      pairs = []
      recursive = Proc.new do |h, prefix|
        h.each_pair do |k,v|
          key = prefix == '' ? k : "#{prefix}[#{k}]"
          v = Patron::Session.escape(v.to_s) if escape_values
          v.is_a?(Hash) ? recursive.call(v, key) : pairs << "#{key}=#{v}"
        end
      end
      recursive.call(hash, '')
      pairs
    end
    
    def build_query_string_from_hash(hash, escape_values=false)
      build_query_pairs_from_hash(hash, escape_values).join('&')
    end
    
  end
end