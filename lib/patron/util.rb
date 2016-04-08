## -------------------------------------------------------------------
##
## Patron HTTP Client: Request class
## Copyright (c) 2008 The Hive http://www.thehive.com/
##
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
##
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
##
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
## THE SOFTWARE.
##
## -------------------------------------------------------------------

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