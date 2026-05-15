# frozen_string_literal: true

module Knitsearch
  # FTS5 match-string builder. Escapes user input so it can't break out of FTS5
  # syntax. Quotes each token, doubles internal quotes, strips control characters,
  # and joins with the specified operator. Returns nil for empty input — the caller
  # decides what to do (typically: return an empty relation).
  module Query
    extend self

    CONTROL_CHARACTERS = /[\x00-\x1f\x7f]/

    def escape(input, operator: :and, prefix: false, match: :word)
      return nil if input.nil?

      cleaned = input.to_s.gsub(CONTROL_CHARACTERS, " ").strip
      return nil if cleaned.empty?

      tokens = cleaned.split(/\s+/).reject(&:empty?)
      return nil if tokens.empty?

      case match
      when :word
        build_word_match(tokens, operator, prefix)
      when :phrase
        build_phrase_match(tokens, operator)
      else
        raise ArgumentError, "match must be :word or :phrase, got: #{match.inspect}"
      end
    end

    private
      def build_word_match(tokens, operator, prefix)
        quoted = tokens.map { |t| %("#{t.gsub('"', '""')}") }
        quoted = quoted.map { |t| "#{t}*" } if prefix

        case operator
        when :and
          quoted.join(" ")
        when :or
          quoted.join(" OR ")
        else
          raise ArgumentError, "operator must be :and or :or, got: #{operator.inspect}"
        end
      end

      def build_phrase_match(tokens, operator)
        if operator == :or
          raise ArgumentError,
                "match: :phrase cannot be combined with operator: :or — a phrase is a single contiguous unit, not a set of terms to OR together"
        end

        escaped_tokens = tokens.map { |t| t.gsub('"', '""') }
        %("#{escaped_tokens.join(' ')}")
      end
  end
end
