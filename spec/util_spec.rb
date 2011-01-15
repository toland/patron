## -------------------------------------------------------------------
##
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
require File.expand_path("./spec") + '/spec_helper.rb'

describe Patron::Util do
  
  describe :build_query_pairs_from_hash do
    it "correctly serializes a simple hash" do
      hash = {:foo => "bar", "baz" => 42}
      array = Patron::Util.build_query_pairs_from_hash(hash)
      array.size.should == 2
      array.should include("foo=bar")
      array.should include("baz=42")
    end
    it "correctly serializes a more complex hash" do
      hash = {
        :foo => "bar",
        :baz => {
          "quux" => {
            :zing => {
              :ying => 42
            }
          },
          :blargh => {
            :spaz => "sox",
            :razz => "matazz"
          }
        }
      }
      array = Patron::Util.build_query_pairs_from_hash(hash)
      array.size.should == 4
      array.should include("foo=bar")
      array.should include("baz[quux][zing][ying]=42")
      array.should include("baz[blargh][spaz]=sox")
      array.should include("baz[blargh][razz]=matazz")
    end
  end
  
  describe :build_query_string_from_hash do
    it "correctly serializes a simple hash" do
      hash = {:foo => "bar", "baz" => 42}
      array = Patron::Util.build_query_string_from_hash(hash).split('&')
      array.size.should == 2
      array.should include("foo=bar")
      array.should include("baz=42")
    end
    it "correctly serializes a more complex hash" do
      hash = {
        :foo => "bar",
        :baz => {
          "quux" => {
            :zing => {
              :ying => 42
            }
          },
          :blargh => {
            :spaz => "sox",
            :razz => "matazz"
          }
        }
      }
      array = Patron::Util.build_query_string_from_hash(hash).split('&')
      array.size.should == 4
      array.should include("foo=bar")
      array.should include("baz[quux][zing][ying]=42")
      array.should include("baz[blargh][spaz]=sox")
      array.should include("baz[blargh][razz]=matazz")
    end
  end
  
end