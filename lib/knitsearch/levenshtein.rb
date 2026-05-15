# frozen_string_literal: true

module Knitsearch
  module Levenshtein
    extend self

    def distance(a, b)
      a = (a || "").to_s
      b = (b || "").to_s
      return b.length if a.empty?
      return a.length if b.empty?

      # Ensure b is the shorter — O(min(a,b)) space
      a, b = b, a if a.length < b.length

      prev = (0..b.length).to_a
      curr = Array.new(b.length + 1)

      a.each_char.with_index(1) do |ac, i|
        curr[0] = i
        b.each_char.with_index(1) do |bc, j|
          cost = ac == bc ? 0 : 1
          curr[j] = [
            curr[j - 1] + 1,    # insert
            prev[j] + 1,        # delete
            prev[j - 1] + cost  # substitute
          ].min
        end
        prev, curr = curr, prev
      end

      prev[b.length]
    end
  end
end
