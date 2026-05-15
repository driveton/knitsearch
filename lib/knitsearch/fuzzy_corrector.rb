# frozen_string_literal: true

module Knitsearch
  module FuzzyCorrector
    extend self

    PREFIX_LENGTH = 3

    def correct(query, vocab_table:, connection:, threshold:, skip_last: false)
      return query if query.nil?

      str = query.to_s
      return query if str.strip.empty?
      return query unless vocab_table_available?(connection, vocab_table)

      tokens = str.split(/\s+/)
      last_index = tokens.length - 1

      corrected = tokens.each_with_index.map do |token, i|
        if skip_last && i == last_index
          token
        else
          correct_token(token, vocab_table: vocab_table, connection: connection, threshold: threshold)
        end
      end

      corrected.join(" ")
    end

    private
      def correct_token(token, vocab_table:, connection:, threshold:)
        lowered = token.downcase
        return token if lowered.length < PREFIX_LENGTH

        prefix = lowered[0, PREFIX_LENGTH]
        candidates = fetch_candidates(connection, vocab_table, prefix)
        return token if candidates.empty?

        scored = candidates
          .map { |term, cnt| [term, cnt.to_i, Knitsearch::Levenshtein.distance(lowered, term)] }
          .select { |_, _, d| d <= threshold }
        return token if scored.empty?

        exact = scored.find { |_, _, d| d == 0 }
        if exact
          max_freq = scored.map { |_, c, _| c }.max
          # Keep the user's word unless it's >1 order of magnitude less common than alternatives.
          # Log-scale comparison is corpus-independent: works equally on small and huge indexes.
          if Math.log10(max_freq.to_f) - Math.log10(exact[1].to_f) < 1.0
            return exact[0]
          end
        end

        best = scored.min_by { |term, cnt, d| [-cnt, d, term] }
        best ? best[0] : token
      end

      def fetch_candidates(connection, vocab_table, prefix)
        binds = [ActiveRecord::Relation::QueryAttribute.new(
          "prefix", "#{prefix}%", ActiveRecord::Type::Value.new
        )]
        result = connection.exec_query(
          "SELECT term, cnt FROM #{connection.quote_table_name(vocab_table)} WHERE term LIKE ?",
          "knitsearch_fuzzy",
          binds
        )
        result.rows
      rescue
        []
      end

      def vocab_table_available?(connection, vocab_table)
        connection.execute("SELECT 1 FROM #{connection.quote_table_name(vocab_table)} LIMIT 0")
        true
      rescue
        false
      end
  end
end
