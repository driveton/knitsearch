# frozen_string_literal: true

module Knitsearch
  module Migration
    extend self

    def connection
      ActiveRecord::Base.connection
    end

    def create_searchable_table(table_name, columns:, tokenizer: nil, dictionary: "simple", prefix: nil, rich_text_columns: [], associated_against: nil)
      raise ArgumentError, "columns must not be empty" if columns.empty?

      if tokenizer.present?
        raise ArgumentError, "tokenizer: is deprecated. Use dictionary: instead (e.g., dictionary: 'english')"
      end

      validate_dictionary(dictionary)
      tokenizer_string = dictionary_to_tokenizer(dictionary)
      fts_table = "#{table_name}_fts"

      # For rich text columns, create shadow columns in the source table if needed
      create_rich_text_shadow_columns(table_name, rich_text_columns)

      # For associated columns, create shadow columns in the source table
      associated_shadow_columns = {}
      if associated_against.present?
        associated_shadow_columns = create_associated_shadow_columns(table_name, associated_against)
      end

      # Build the FTS column list: use shadow column names for rich text fields and associated fields
      column_names = columns.is_a?(Hash) ? columns.keys : columns
      # Ensure column names are strings for consistent handling
      column_names = column_names.map(&:to_s)
      # Convert rich_text_columns to strings for consistent comparison
      rich_text_columns = rich_text_columns.map(&:to_s)
      fts_column_names = column_names.map do |col|
        rich_text_columns.include?(col) ? "#{col}_plain_text" : col
      end
      fts_column_names.concat(associated_shadow_columns.keys)

      column_list = fts_column_names.map { |c| connection.quote_column_name(c.to_s) }.join(", ")

      # Build FTS5 options. Each prefix size listed adds a sub-index to the FTS5 data file.
      # prefix: true uses [2, 3] (safe default, ~2× index size). prefix: [2, 3, 4] customizes.
      fts_options = [
        "content=#{connection.quote(table_name)}",
        "content_rowid='id'",
        "tokenize=#{connection.quote(tokenizer_string)}"
      ]

      if prefix
        sizes = prefix == true ? [ 2, 3 ] : Array(prefix).map(&:to_i)
        fts_options << "prefix=#{connection.quote(sizes.join(' '))}"
      end

      # Create FTS5 virtual table with external content
      sql = "CREATE VIRTUAL TABLE #{connection.quote_table_name(fts_table)} USING fts5(" \
            "#{column_list}, " \
            "#{fts_options.join(', ')}" \
            ")"
      connection.execute(sql)

      # Vocab table — read-only virtual table exposing the FTS5 dictionary
      # for fuzzy correction. Standard SQLite feature, no extension.
      vocab_table = "#{fts_table}_vocab"
      connection.execute(
        "CREATE VIRTUAL TABLE #{connection.quote_table_name(vocab_table)} " \
        "USING fts5vocab(#{connection.quote(fts_table)}, 'row')"
      )

      # Build trigger value references: use shadow column names for rich text fields and associated fields
      trigger_values = column_names.map do |col|
        col_ref = rich_text_columns.include?(col) ? "#{col}_plain_text" : col
        "new.#{connection.quote_column_name(col_ref)}"
      end
      # Add associated shadow columns to trigger values
      trigger_values.concat(associated_shadow_columns.keys.map { |col| "new.#{connection.quote_column_name(col.to_s)}" })
      trigger_values_str = trigger_values.join(", ")

      trigger_values_old = column_names.map do |col|
        col_ref = rich_text_columns.include?(col) ? "#{col}_plain_text" : col
        "old.#{connection.quote_column_name(col_ref)}"
      end
      # Add associated shadow columns to trigger values (for delete trigger)
      trigger_values_old.concat(associated_shadow_columns.keys.map { |col| "old.#{connection.quote_column_name(col.to_s)}" })
      trigger_values_old_str = trigger_values_old.join(", ")

      # After insert trigger: add new row to index
      insert_trigger = "CREATE TRIGGER #{connection.quote_table_name("#{table_name}_ai")} AFTER INSERT ON #{connection.quote_table_name(table_name)} BEGIN " \
                       "INSERT INTO #{connection.quote_table_name(fts_table)}(rowid, #{column_list}) VALUES (new.id, #{trigger_values_str}); " \
                       "END"
      connection.execute(insert_trigger)

      # After delete trigger: remove row from index
      delete_trigger = "CREATE TRIGGER #{connection.quote_table_name("#{table_name}_ad")} AFTER DELETE ON #{connection.quote_table_name(table_name)} BEGIN " \
                       "INSERT INTO #{connection.quote_table_name(fts_table)}(#{fts_table}, rowid, #{column_list}) VALUES('delete', old.id, #{trigger_values_old_str}); " \
                       "END"
      connection.execute(delete_trigger)

      # After update trigger: delete old, insert new
      update_trigger = "CREATE TRIGGER #{connection.quote_table_name("#{table_name}_au")} AFTER UPDATE ON #{connection.quote_table_name(table_name)} BEGIN " \
                       "INSERT INTO #{connection.quote_table_name(fts_table)}(#{fts_table}, rowid, #{column_list}) VALUES('delete', old.id, #{trigger_values_old_str}); " \
                       "INSERT INTO #{connection.quote_table_name(fts_table)}(rowid, #{column_list}) VALUES (new.id, #{trigger_values_str}); " \
                       "END"
      connection.execute(update_trigger)
    end

    def drop_searchable_table(table_name)
      fts_table = "#{table_name}_fts"

      connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_table_name("#{table_name}_ai")}")
      connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_table_name("#{table_name}_ad")}")
      connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_table_name("#{table_name}_au")}")
      connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name("#{fts_table}_vocab")}")
      connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name(fts_table)}")

      %w[data idx docsize config].each do |suffix|
        connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name("#{fts_table}_#{suffix}")}") rescue nil
      end
    end

    def create_multisearch_table
      connection.execute("DROP TABLE IF EXISTS knitsearches_fts") rescue nil
      connection.execute("DROP TRIGGER IF EXISTS knitsearches_ai") rescue nil
      connection.execute("DROP TRIGGER IF EXISTS knitsearches_ad") rescue nil
      connection.execute("DROP TRIGGER IF EXISTS knitsearches_au") rescue nil
      connection.execute("DROP TABLE IF EXISTS knitsearches") rescue nil

      connection.execute(<<~SQL)
        CREATE TABLE knitsearches (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          searchable_type VARCHAR(255) NOT NULL,
          searchable_id INTEGER NOT NULL,
          content TEXT,
          created_at DATETIME,
          updated_at DATETIME
        )
      SQL

      connection.execute("CREATE UNIQUE INDEX idx_knitsearches_poly ON knitsearches (searchable_type, searchable_id)")
      connection.execute("CREATE INDEX idx_knitsearches_type ON knitsearches (searchable_type)")

      connection.execute(<<~SQL)
        CREATE VIRTUAL TABLE knitsearches_fts USING fts5(
          content,
          content='knitsearches',
          content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        )
      SQL

      connection.execute(<<~SQL)
        CREATE TRIGGER knitsearches_ai AFTER INSERT ON knitsearches BEGIN
          INSERT INTO knitsearches_fts(rowid, content) VALUES (new.id, new.content);
        END
      SQL

      connection.execute(<<~SQL)
        CREATE TRIGGER knitsearches_ad AFTER DELETE ON knitsearches BEGIN
          INSERT INTO knitsearches_fts(knitsearches_fts, rowid, content) VALUES('delete', old.id, old.content);
        END
      SQL

      connection.execute(<<~SQL)
        CREATE TRIGGER knitsearches_au AFTER UPDATE ON knitsearches BEGIN
          INSERT INTO knitsearches_fts(knitsearches_fts, rowid, content) VALUES('delete', old.id, old.content);
          INSERT INTO knitsearches_fts(rowid, content) VALUES (new.id, new.content);
        END
      SQL
    end

    def drop_multisearch_table
      connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_table_name('knitsearches_au')}")
      connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_table_name('knitsearches_ad')}")
      connection.execute("DROP TRIGGER IF EXISTS #{connection.quote_table_name('knitsearches_ai')}")
      connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name('knitsearches_fts')}")

      # Explicitly drop FTS5 shadow tables for knitsearches_fts
      %w[data idx docsize config].each do |suffix|
        connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name("knitsearches_fts_#{suffix}")}")
      end

      connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name('knitsearches')}")
    end

    private

      def create_rich_text_shadow_columns(table_name, rich_text_columns)
        rich_text_columns.each do |col|
          shadow_col = "#{col}_plain_text"
          # Only create if it doesn't already exist
          unless connection.column_exists?(table_name, shadow_col)
            connection.add_column(table_name, shadow_col, :text)
          end
        end
      end

      def create_associated_shadow_columns(table_name, associated_against)
        result = {}
        associated_against.each do |assoc_name, columns_spec|
          columns_list = columns_spec.is_a?(Array) ? columns_spec : columns_spec.keys
          columns_list.each do |col|
            shadow_col = "#{assoc_name}_#{col}_plain_text"
            # Only create if it doesn't already exist
            unless connection.column_exists?(table_name, shadow_col)
              connection.add_column(table_name, shadow_col, :text)
            end
            result[shadow_col] = true
          end
        end
        result
      end

      def validate_dictionary(dictionary)
        unless Knitsearch::SUPPORTED_DICTIONARIES.include?(dictionary)
          raise Knitsearch::UnknownDictionaryError,
                "Unknown dictionary: #{dictionary.inspect}. Supported: #{Knitsearch::SUPPORTED_DICTIONARIES.inspect}"
        end
      end

      def dictionary_to_tokenizer(dictionary)
        case dictionary
        when "simple"
          Knitsearch::TOKENIZER_PRESETS[:unicode]
        when "english"
          Knitsearch::TOKENIZER_PRESETS[:porter]
        when "trigram"
          Knitsearch::TOKENIZER_PRESETS[:trigram]
        else
          raise Knitsearch::UnknownDictionaryError, "Unsupported dictionary: #{dictionary.inspect}"
        end
      end
  end
end
