require File.expand_path("./spec") + '/spec_helper.rb'

describe Patron::Util do

  describe :build_query_pairs_from_hash do
    
    it "correctly serializes a simple hash" do
      hash = {:foo => "bar", "baz" => 42}
      array = Patron::Util.build_query_pairs_from_hash(hash)
      expect(array.size).to be == 2
      expect(array).to include("foo=bar")
      expect(array).to include("baz=42")
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
      expect(array.size).to be == 4
      expect(array).to include("foo=bar")
      expect(array).to include("baz[quux][zing][ying]=42")
      expect(array).to include("baz[blargh][spaz]=sox")
      expect(array).to include("baz[blargh][razz]=matazz")
    end
  end

  describe :build_query_string_from_hash do
    it "correctly serializes a simple hash" do
      hash = {:foo => "bar", "baz" => 42}
      array = Patron::Util.build_query_string_from_hash(hash).split('&')
      expect(array.size).to be == 2
      expect(array).to include("foo=bar")
      expect(array).to include("baz=42")
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
      expect(array.size).to be == 4
      expect(array).to include("foo=bar")
      expect(array).to include("baz[quux][zing][ying]=42")
      expect(array).to include("baz[blargh][spaz]=sox")
      expect(array).to include("baz[blargh][razz]=matazz")
    end
  end

end
