# frozen_string_literal: true

require "cgi"

module Knitsearch
  # The user-facing concern. Include in an ActiveRecord model and call
  # `searchable_by` with the columns you want indexed:
  #
  #   class Article < ApplicationRecord
  #     include Knitsearch::Model
  #     searchable_by against: { title: 'A', body: 'B' }
  #   end
  #
  # Sync happens via SQLite triggers, not ActiveRecord callbacks.
  # Triggers are created in the migration and fire atomically inside
  # the source transaction.
  module Model
    extend ActiveSupport::Concern

    class_methods do
      def searchable_by(**kwargs)
        @rich_text_mapping = {}
        @associated_mapping = {}

        columns, associated, options = parse_searchable_args(kwargs)

        columns.each do |col, weight|
          unless weight.is_a?(Numeric) && weight > 0
            raise ArgumentError, "Weight for #{col} must be a positive number, got #{weight.inspect}"
          end
        end

        # Validate and merge associated columns into the main columns hash
        associated.each do |assoc_name, assoc_columns|
          assoc_columns.each do |col, weight|
            unless weight.is_a?(Numeric) && weight > 0
              raise ArgumentError, "Weight for #{assoc_name}.#{col} must be a positive number, got #{weight.inspect}"
            end
          end
        end

        columns = columns.freeze
        associated = associated.freeze

        fts_table = "#{table_name}_fts"
        if knitsearch_fts_table_available?(fts_table)
          fts_columns = connection.columns(fts_table).map(&:name)

          # Check both regular and rich-text shadow columns
          columns_to_check = columns.keys.map { |col| rich_text_mapping[col]&.to_s || col }
          # Add associated shadow columns
          associated.each do |assoc_name, assoc_cols|
            assoc_cols.keys.each do |col|
              columns_to_check << "#{assoc_name}_#{col}_plain_text"
            end
          end
          missing = columns_to_check.uniq - fts_columns

          if missing.any?
            raise Knitsearch::SchemaMismatchError,
                  "#{name} declares searchable_by(#{columns.keys.inspect}) but FTS table " \
                  "`#{fts_table}` is missing columns: #{missing.inspect}. " \
                  "Update the migration or the searchable_by declaration."
          end
        end

        unless respond_to?(:searchable_columns)
          class_attribute :searchable_columns
          class_attribute :searchable_options
          class_attribute :searchable_dictionary, default: "simple"
          class_attribute :knitsearch_callbacks_installed, default: false
        end

        dictionary = parse_dictionary(options)
        self.searchable_columns = columns
        self.searchable_options = options.freeze
        self.searchable_dictionary = dictionary

        # Store the associated mapping so it can be accessed later
        @associated_mapping = associated

        if (rich_text_mapping.any? || associated.any?) && !knitsearch_callbacks_installed
          install_rich_text_sync if rich_text_mapping.any?
          install_associated_sync(associated) if associated.any?
          self.knitsearch_callbacks_installed = true
        end
      end

      def search(query, limit: nil, highlight: nil, snippet: nil, operator: :and, match: :word, prefix: nil, fallback_below: nil, fuzzy: nil)
        raise ArgumentError, "operator must be :and or :or, got: #{operator.inspect}" unless [:and, :or].include?(operator)
        raise ArgumentError, "match must be :word or :phrase, got: #{match.inspect}" unless [:word, :phrase].include?(match)

        if fuzzy && fuzzy > 0
          query = Knitsearch::FuzzyCorrector.correct(
            query,
            vocab_table: vocab_table_name,
            connection: connection,
            threshold: fuzzy,
            skip_last: (prefix == true)
          )
        end

        strict = build_search_relation(query, limit: limit, highlight: highlight, snippet: snippet, operator: operator, match: match, prefix: prefix)

        if fallback_eligible?(fallback_below, operator)
          apply_fallback(query, strict, fallback_below, limit: limit, highlight: highlight, snippet: snippet, match: match, prefix: prefix)
        else
          strict
        end
      end

      def suggest(query, limit: 10, fallback_below: nil, fuzzy: nil)
        search(query, prefix: true, limit: limit, fallback_below: fallback_below, fuzzy: fuzzy)
      end

      def suggest_correction(query, threshold: 1)
        return nil if query.blank?

        str = query.to_s
        return nil if str.strip.empty?

        corrected = Knitsearch::FuzzyCorrector.correct(
          query,
          vocab_table: vocab_table_name,
          connection: connection,
          threshold: threshold,
          skip_last: false
        )

        corrected == str ? nil : corrected
      end

      def knitsearch_backfill!
        if rich_text_mapping.any?
          backfill_shadow_columns
        else
          reindex!
        end
      end

      def reindex!
        fts_table = "#{table_name}_fts"
        quoted_fts = connection.quote_table_name(fts_table)
        connection.execute("INSERT INTO #{quoted_fts}(#{quoted_fts}) VALUES('rebuild')")
      end

      def vocab_table_name
        "#{table_name}_fts_vocab"
      end

      def rich_text_mapping
        @rich_text_mapping ||= {}
      end

      def associated_mapping
        @associated_mapping ||= {}
      end

      def associated_shadow_columns
        result = {}
        associated_mapping.each do |assoc_name, assoc_columns|
          assoc_columns.each do |col, weight|
            shadow_col = "#{assoc_name}_#{col}_plain_text"
            result[shadow_col] = weight
          end
        end
        result
      end

      def fts_column_order
        cols = searchable_columns.keys.map { |col| rich_text_mapping[col]&.to_s || col }
        cols.concat(associated_shadow_columns.keys)
        cols
      end

      private

        def build_search_relation(query, limit:, highlight:, snippet:, operator:, match:, prefix: nil)
          prefix = prefix.nil? ? searchable_options.dig(:using, :fts5, :prefix) : prefix
          match_string = Knitsearch::Query.escape(query, operator: operator, prefix: prefix, match: match)
          return none if match_string.nil?

          validate_highlight_columns(highlight) if highlight
          validate_snippet_columns(snippet) if snippet

          fts_table = "#{table_name}_fts"
          quoted_fts = connection.quote_table_name(fts_table)
          quoted_source = connection.quote_table_name(table_name)

          weights = searchable_columns.values
          bm25_args = ([quoted_fts] + weights.map(&:to_s)).join(", ")

          relation = joins("INNER JOIN #{quoted_fts} ON #{quoted_fts}.rowid = #{quoted_source}.id")
                       .where("#{quoted_fts} MATCH ?", match_string)
                       .order(Arel.sql("bm25(#{bm25_args})"))

          # Add score when highlight or snippet are present (to avoid breaking .count()/.exists?())
          if highlight || snippet
            selects = ["#{quoted_source}.*", "bm25(#{bm25_args}) AS searchable_score"]
            selects.concat(highlight_selects(highlight, fts_table)) if highlight
            selects.concat(snippet_selects(snippet, fts_table)) if snippet
            relation = relation.select(selects.join(", "))
          end

          relation = relation.limit(limit) if limit
          relation
        end

        def fallback_eligible?(fallback_below, operator)
          fallback_below && fallback_below > 0 && operator == :and
        end

        def apply_fallback(query, strict, threshold, limit:, highlight:, snippet:, match:, prefix: nil)
          primary = strict.to_a
          return primary if primary.size >= threshold

          secondary = build_search_relation(
            query,
            limit: limit,
            highlight: highlight,
            snippet: snippet,
            operator: :or,
            match: :word,
            prefix: prefix
          ).to_a

          merge_search_results(primary, secondary, limit: limit)
        end

        def merge_search_results(primary, secondary, limit:)
          seen_ids = primary.map(&:id).to_set
          extras   = secondary.reject { |record| seen_ids.include?(record.id) }
          merged   = primary + extras
          limit ? merged.first(limit) : merged
        end

        def parse_searchable_args(kwargs)
          unless kwargs.key?(:against)
            raise ArgumentError,
                  "searchable_by requires `against:` keyword. " \
                  "Example: searchable_by against: { title: 'A', bio: 'B' }"
          end

          columns = kwargs[:against].transform_values { |v| resolve_weight(v) }
          options = kwargs.slice(:using)
          associated = normalize_associated_against(kwargs[:associated_against])

          # Detect ActionText rich-text fields and build mapping to shadow columns.
          detect_rich_text_fields(columns)

          [columns.transform_keys(&:to_s), associated, options]
        end

        def normalize_associated_against(associated_against)
          return {} unless associated_against

          result = {}

          associated_against.each do |assoc_name, columns_spec|
            assoc_name_str = assoc_name.to_s
            reflection = reflect_on_association(assoc_name)

            unless reflection
              raise Knitsearch::ConfigurationError,
                    "Associated field #{assoc_name.inspect} is not a declared association on #{name}"
            end

            case reflection.macro
            when :belongs_to
              if reflection.options[:polymorphic]
                raise Knitsearch::ConfigurationError,
                      "Polymorphic belongs_to #{assoc_name.inspect} is not supported in this release."
              end
            when :has_many
              if reflection.through_reflection?
                # has_many :through is allowed
                if reflection.source_reflection.polymorphic?
                  raise Knitsearch::ConfigurationError,
                        "Polymorphic source on has_many :through #{assoc_name.inspect} is not supported."
                end
              elsif reflection.options[:polymorphic]
                raise Knitsearch::ConfigurationError,
                      "Polymorphic has_many #{assoc_name.inspect} is not supported in this release."
              end
            when :has_one
              raise Knitsearch::ConfigurationError,
                    "has_one associations are not yet supported. Only belongs_to and has_many are available."
            else
              raise Knitsearch::ConfigurationError,
                    "Associated field #{assoc_name.inspect} is a #{reflection.macro}, but only belongs_to and has_many are supported."
            end

            # Normalize columns_spec: Array → Hash with "C" weight, Hash stays as is
            if columns_spec.is_a?(Array)
              columns_spec = columns_spec.index_with { "C" }
            end

            columns_with_weights = columns_spec.transform_values { |v| resolve_weight(v) }
            result[assoc_name_str] = columns_with_weights
          end

          result
        end

        def parse_dictionary(options)
          dictionary = options.dig(:using, :fts5, :dictionary) || "simple"

          if dictionary.is_a?(Symbol)
            raise ArgumentError,
                  "dictionary must be a string (e.g., dictionary: \"english\"), not a symbol. " \
                  "Remove the colon: dictionary: \"#{dictionary}\""
          end

          unless Knitsearch::SUPPORTED_DICTIONARIES.include?(dictionary)
            raise Knitsearch::UnknownDictionaryError,
                  "Unknown dictionary: #{dictionary.inspect}. Supported: #{Knitsearch::SUPPORTED_DICTIONARIES.inspect}"
          end

          if dictionary == "trigram" && options.dig(:using, :fts5, :prefix)
            raise ArgumentError,
                  "dictionary: \"trigram\" cannot be combined with prefix: — the trigram tokenizer " \
                  "already supports substring matching. Pick one."
          end

          dictionary
        end

        def detect_rich_text_fields(columns)
          rich_text_field_names =
            if respond_to?(:rich_text_association_names)
              # Rails 8.1+: returns association names like :rich_text_body — strip the prefix
              rich_text_association_names.map { |n| n.to_s.sub(/^rich_text_/, "").to_sym }
            elsif respond_to?(:rich_text_class_attributes)
              # Rails 7.x – 8.0
              rich_text_class_attributes.keys
            elsif respond_to?(:rich_text_attributes)
              # legacy
              rich_text_attributes
            else
              []
            end

          columns.each_key do |field|
            field_sym = field.to_sym
            next unless rich_text_field_names.include?(field_sym)

            shadow_column = "#{field}_plain_text".to_sym
            rich_text_mapping[field.to_s] = shadow_column
          end
        end

        def install_rich_text_sync
          before_save :sync_rich_text_to_shadow_columns, if: :should_sync_rich_text?
        end

        def install_associated_sync(associated)
          before_save :sync_associated_to_shadow_columns, if: :should_sync_associated?

          # Register this model's dependents on parent classes or register children on child classes
          associated.each do |assoc_name, columns|
            reflection = reflect_on_association(assoc_name)

            # Build shadow map: { shadow_column => source_column }
            shadow_map = {}
            columns.each do |col, weight|
              shadow_col = "#{assoc_name}_#{col}_plain_text"
              shadow_map[shadow_col.to_sym] = col
            end

            if reflection.macro == :belongs_to
              parent_class = reflection.klass
              foreign_key = reflection.foreign_key.to_sym
              Knitsearch.register_belongs_to_dependent(parent_class, self, foreign_key, shadow_map)
            elsif reflection.macro == :has_many
              if reflection.through_reflection?
                # has_many :through case
                join_class = reflection.through_reflection.klass
                target_class = reflection.klass
                parent_fk = reflection.through_reflection.foreign_key.to_sym
                target_fk = reflection.source_reflection.foreign_key.to_sym
                Knitsearch.register_has_many_through_dependent(
                  join_class: join_class,
                  target_class: target_class,
                  parent_class: self,
                  parent_fk: parent_fk,
                  target_fk: target_fk,
                  parent_assoc: assoc_name.to_sym,
                  shadow_map: shadow_map
                )
              else
                # Plain has_many case
                child_class = reflection.klass
                inverse_fk = reflection.foreign_key.to_sym
                Knitsearch.register_has_many_dependent(child_class, self, inverse_fk, shadow_map, assoc_name.to_sym)
              end
            end
          end
        end

        def backfill_shadow_columns
          find_each do |record|
            shadow_updates = {}
            rich_text_mapping.each do |declared_field, shadow_column|
              rich_text_body = record.send(declared_field)
              plain_text = if rich_text_body.nil?
                             nil
                           else
                             record.send(:extract_plain_text_from_action_text, rich_text_body)
                           end
              shadow_updates[shadow_column] = plain_text
            end

            record.update_columns(shadow_updates) if shadow_updates.any?
          end
        end

        def resolve_weight(value)
          if value.is_a?(String) && Knitsearch::WEIGHT_BUCKETS.key?(value.upcase)
            Knitsearch::WEIGHT_BUCKETS[value.upcase]
          else
            value.to_f
          end
        end

        def knitsearch_fts_table_available?(fts_table)
          # Virtual FTS5 tables don't appear in connection.tables, so we need to try
          # querying them directly instead of using table_exists?
          connection.execute("SELECT 1 FROM #{connection.quote_table_name(fts_table)} LIMIT 0")
          true
        rescue
          false
        end

        def validate_highlight_columns(columns)
          cols = Array(columns).map(&:to_s)
          invalid = cols - searchable_columns.keys
          return if invalid.empty?

          raise Knitsearch::ColumnError,
                "highlight: contains columns not in searchable_by: #{invalid.inspect}"
        end

        def validate_snippet_columns(snippets)
          cols = case snippets
                 when Array then snippets.map(&:to_s)
                 when Hash then snippets.keys.map(&:to_s)
                 else return
                 end
          invalid = cols - searchable_columns.keys
          return if invalid.empty?

          raise Knitsearch::ColumnError,
                "snippet: contains columns not in searchable_by: #{invalid.inspect}"
        end

        def highlight_selects(columns, fts_table)
          cols = Array(columns)
          cols.map { |col| highlight_select(fts_table, col) }
        end

        def snippet_selects(snippets, fts_table)
          pairs = case snippets
                  when Array then snippets.map { |c| [c, 20] }
                  when Hash then snippets.to_a
                  else raise ArgumentError, "snippet: must be Array or Hash"
                  end

          pairs.map { |col, tokens| snippet_select(fts_table, col, tokens) }
        end

        def highlight_select(fts_table, column)
          declared_col = column.to_s
          col_index = searchable_columns.keys.index(declared_col)
          raise Knitsearch::ColumnError, "#{column} is not in searchable_by columns" unless col_index

          mark_opening = Knitsearch::Highlighter.opening_mark
          mark_closing = Knitsearch::Highlighter.closing_mark
          quoted_fts = connection.quote_table_name(fts_table)

          "highlight(#{quoted_fts}, #{col_index}, #{connection.quote(mark_opening)}, #{connection.quote(mark_closing)}) AS searchable_highlight_#{column}"
        end

        def snippet_select(fts_table, column, tokens)
          declared_col = column.to_s
          col_index = searchable_columns.keys.index(declared_col)
          raise Knitsearch::ColumnError, "#{column} is not in searchable_by columns" unless col_index

          token_count = Integer(tokens)
          raise ArgumentError, "snippet token count must be positive, got: #{tokens.inspect}" unless token_count > 0

          mark_opening = Knitsearch::Highlighter.opening_mark
          mark_closing = Knitsearch::Highlighter.closing_mark
          quoted_fts = connection.quote_table_name(fts_table)

          "snippet(#{quoted_fts}, #{col_index}, #{connection.quote(mark_opening)}, #{connection.quote(mark_closing)}, '...', #{token_count}) AS searchable_snippet_#{column}"
        end
    end

    def should_sync_rich_text?
      self.class.rich_text_mapping.any?
    end

    def sync_rich_text_to_shadow_columns
      self.class.rich_text_mapping.each do |declared_field, shadow_column|
        rich_text_body = send(declared_field)
        plain_text = if rich_text_body.nil?
                       nil
                     else
                       extract_plain_text_from_action_text(rich_text_body)
                     end
        send("#{shadow_column}=", plain_text)
      end
    end

    def should_sync_associated?
      self.class.associated_mapping.any?
    end

    def sync_associated_to_shadow_columns
      self.class.associated_mapping.each do |assoc_name, columns|
        reflection = self.class.reflect_on_association(assoc_name)

        columns.each do |col, _weight|
          shadow_column = "#{assoc_name}_#{col}_plain_text"

          if reflection.macro == :belongs_to
            # belongs_to: sync the parent's value
            assoc_object = send(assoc_name)
            value = if assoc_object.nil?
                      nil
                    else
                      assoc_object.send(col)&.to_s
                    end
            send("#{shadow_column}=", value)
          elsif reflection.macro == :has_many
            # has_many (both plain and through): sync from the live association
            # Plain has_many: synced on create via before_save, then updated from child side
            # has_many :through: synced on create via before_save, then updated from join/target side
            values = send(assoc_name).pluck(col).compact.map(&:to_s)
            send("#{shadow_column}=", values.any? ? values.join(" ") : nil)
          end
        end
      end
    end

    def search_highlight(column)
      raw = self["searchable_highlight_#{column}"]
      return nil if raw.nil?
      Knitsearch::Highlighter.render(raw)
    end

    def search_snippet(column)
      raw = self["searchable_snippet_#{column}"]
      return nil if raw.nil?
      Knitsearch::Highlighter.render(raw)
    end

    def searchable_score
      self["searchable_score"]
    end

    def knitsearch_cascade_to_children
      dependents = Knitsearch.belongs_to_dependents[self.class]
      return unless dependents

      dependents.each do |dependent|
        child_model = dependent[:model]
        fk = dependent[:foreign_key]
        shadow_map = dependent[:columns]

        # Build SET clause for update_all: { shadow_col => new_parent_value, ... }
        updates = {}
        shadow_map.each do |shadow_col, source_col|
          value = send(source_col)&.to_s
          updates[shadow_col] = value
        end

        child_model.where(fk => id).update_all(updates)
      end
    end

    private

      # Output is written to a shadow column for FTS indexing only — never
      # rendered to a view. The regex stripper is not safe HTML sanitization.
      def extract_plain_text_from_action_text(rich_text_body)
        # ActionText body is serialized as HTML. Extract plain text by:
        # 1. Get the raw HTML
        # 2. Strip action-text-attachment tags
        # 3. Add space before closing block elements
        # 4. Remove HTML tags
        # 5. Collapse whitespace
        # 6. Unescape HTML entities
        html = rich_text_body.to_html
        return "" if html.blank?

        # Remove <action-text-attachment> elements
        text = html.gsub(/<action-text-attachment[^>]*>.*?<\/action-text-attachment>/m, "")

        # Add space before block-closing tags to prevent word concatenation
        text = text.gsub(%r{</(?:p|div|blockquote|pre|li|tr|td|th|h[1-6])>}, " ")

        # Remove all remaining HTML tags
        text = text.gsub(/<[^>]*>/, "")

        # Replace multiple whitespace with single space, then strip
        text = text.gsub(/\s+/, " ").strip

        # Unescape HTML entities
        CGI.unescape_html(text)
      end
  end
end
