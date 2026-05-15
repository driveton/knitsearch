# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"
require "active_record"

module Knitsearch
  class InstallGenerator < ::Rails::Generators::Base
    include ::Rails::Generators::Migration

    desc "Create FTS5 search index for a model. Usage: " \
         "bin/rails generate knitsearch:install Article title body"

    argument :model_name, type: :string, banner: "MODEL"
    argument :columns, type: :array, default: [], banner: "column1 column2 ..."

    class_option :dictionary, type: :string, default: "simple",
                 desc: "Dictionary for stemming: simple (none), english (default: simple)"
    class_option :tokenizer, type: :string, default: nil,
                 desc: "[DEPRECATED] Use --dictionary instead"
    class_option :associated, type: :array, default: [],
                 desc: "Associated fields to index, format: assoc:column. Repeat for multiple. Example: --associated user:display_name --associated tags:name"

    source_root File.expand_path("templates", __dir__)

    def self.next_migration_number(dirname)
      ::ActiveRecord::Generators::Base.next_migration_number(dirname)
    end

    def verify_sqlite_adapter
      adapter = primary_adapter_from_configuration
      return if adapter == "sqlite3"

      raise ::Thor::Error,
            "knitsearch requires SQLite. Detected adapter: #{adapter.inspect}. " \
            "Use pg_search or your database's native FTS instead."
    end

    def verify_columns_provided
      return unless columns.empty?

      raise ::Thor::Error,
            "knitsearch:install requires at least one column to index. " \
            "Example: bin/rails generate knitsearch:install Article title body"
    end

    def verify_table_exists
      return if table_exists?(source_table_name)

      raise ::Thor::Error,
            "Table `#{source_table_name}` does not exist. " \
            "Run `bin/rails db:migrate` first to create the #{model_name} table."
    end

    def verify_column_names
      invalid = columns.reject { |c| c.match?(/\A[a-z_][a-z0-9_]*\z/) }
      return if invalid.empty?

      raise ::Thor::Error,
            "Column names must be lowercase identifiers (letters, digits, underscores). " \
            "Invalid: #{invalid.inspect}"
    end

    def verify_migration_not_exists
      pattern = File.join(destination_root, "db/migrate/*_create_#{fts_table_name}.rb")
      existing = Dir.glob(pattern)
      return if existing.empty?

      raise ::Thor::Error,
            "A migration for #{fts_table_name} already exists: #{File.basename(existing.first)}. " \
            "Delete it first if you want to regenerate."
    end

    def create_migration
      timestamp = self.class.next_migration_number("db/migrate")
      migration_filename = "#{timestamp}_create_#{fts_table_name}.rb"
      migration_path = File.join(destination_root, "db/migrate", migration_filename)

      if options[:tokenizer].present?
        puts "WARNING: --tokenizer is deprecated. Use --dictionary instead."
      end

      rich_text_cols = detect_rich_text_columns
      dictionary = options[:dictionary] || "simple"
      associated = parse_associated_against

      associated_clause = associated.any? ? ",\n        associated_against: #{associated.inspect}" : ""

      migration_content = <<~RUBY
        class Create#{fts_table_name.camelize} < ActiveRecord::Migration#{migration_version}
          include Knitsearch::Migration

          def up
            create_searchable_table #{source_table_name.inspect},
              columns: #{columns.inspect},
              dictionary: #{dictionary.inspect},
              rich_text_columns: #{rich_text_cols.inspect}#{associated_clause}
          end

          def down
            drop_searchable_table #{source_table_name.inspect}
          end
        end
      RUBY

      create_file migration_path, migration_content

      puts "\nMigration created: #{migration_path}"
      puts "\nNext steps:"
      puts "  1. bin/rails db:migrate"
      if associated.any?
        puts "  2. Add to #{model_name} model:"
        puts "       searchable_by("
        puts "         against: { #{columns.map { |c| "#{c}: \"A\"" }.join(", ")} },"
        puts "         associated_against: #{associated.inspect}"
        puts "       )"
        puts "  3. bin/rails knitsearch:backfill[#{model_name}]"
      else
        puts "  2. Add to #{model_name} model:"
        puts "       searchable_by(against: { #{columns.map { |c| "#{c}: \"A\"" }.join(", ")} })"
        puts "  3. bin/rails knitsearch:backfill[#{model_name}]"
      end
    end

    no_tasks do
      def model_class
        @model_class ||= model_name.classify.constantize
      rescue ::NameError
        raise ::Thor::Error,
              "Could not find model #{model_name}. " \
              "Generate it first: bin/rails generate model #{model_name}"
      end

      def source_table_name
        model_class.table_name
      end

      def fts_table_name
        "#{source_table_name}_fts"
      end

      def migration_class_name
        "Create#{fts_table_name.camelize}"
      end

      def migration_version
        "[#{::Rails::VERSION::MAJOR}.#{::Rails::VERSION::MINOR}]"
      end

      def table_exists?(table_name)
        ::ActiveRecord::Base.connection.table_exists?(table_name)
      end

      def detect_rich_text_columns
        columns.select do |col|
          model_class.respond_to?(:rich_text_attributes) &&
            model_class.rich_text_attributes.include?(col.to_sym)
        end
      end

      def parse_associated_against
        return {} if options[:associated].empty?

        result = {}

        options[:associated].each do |item|
          parts = item.split(":")
          if parts.size < 2
            raise ::Thor::Error,
                  "Invalid --associated format: #{item.inspect}. " \
                  "Expected: association:column (e.g., user:name) or association:column:weight (e.g., tags:name:C)"
          end

          assoc_name = parts[0].to_sym
          column_name = parts[1].to_sym
          weight = parts[2]&.upcase || "C"

          unless [:A, :B, :C, :D].include?(weight.to_sym)
            raise ::Thor::Error,
                  "Invalid weight for #{assoc_name}:#{column_name}: #{weight.inspect}. " \
                  "Must be A, B, C, or D."
          end

          unless model_class.reflect_on_association(assoc_name)
            raise ::Thor::Error,
                  "#{model_name} does not have association #{assoc_name.inspect}. " \
                  "Check your model's association declarations."
          end

          result[assoc_name] = [column_name] unless result[assoc_name]
        end

        result
      end
    end

    private
      def primary_adapter_from_configuration
        env_name = (defined?(::Rails) && ::Rails.respond_to?(:env)) ? ::Rails.env.to_s : (ENV["RAILS_ENV"] || "development")
        configs  = ::ActiveRecord::Base.configurations.configs_for(env_name: env_name)
        return nil if configs.empty?

        primary = configs.find { |c| c.name == "primary" } || configs.first
        primary.adapter
      end
  end
end
