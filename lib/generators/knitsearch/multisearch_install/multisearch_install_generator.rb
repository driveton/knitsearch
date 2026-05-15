# frozen_string_literal: true

require "rails/generators"
require "rails/generators/migration"
require "rails/generators/active_record"
require "active_record"

module Knitsearch
  class MultisearchInstallGenerator < ::Rails::Generators::Base
    include ::Rails::Generators::Migration

    desc "Create FTS5 multi-model search index. Usage: bin/rails generate knitsearch:multisearch_install"

    class_option :force, type: :boolean, default: false, desc: "Overwrite if migration already exists"

    source_root File.expand_path("templates", __dir__)

    def self.next_migration_number(dirname)
      ::ActiveRecord::Generators::Base.next_migration_number(dirname)
    end

    def verify_sqlite_adapter
      adapter = primary_adapter_from_configuration
      return if adapter == "sqlite3"

      raise ::Thor::Error,
            "knitsearch multi-model search requires SQLite. Detected adapter: #{adapter.inspect}. " \
            "Use a different full-text search solution for your database."
    end

    def verify_table_not_exists
      return if !table_exists?("knitsearches")

      return if options[:force]

      raise ::Thor::Error,
            "Table `knitsearches` already exists. " \
            "Run `bin/rails generate knitsearch:multisearch_install --force` to overwrite."
    end

    def create_migration
      timestamp = self.class.next_migration_number("db/migrate")
      migration_filename = "#{timestamp}_create_knitsearches_multisearch.rb"
      migration_path = File.join(destination_root, "db/migrate", migration_filename)

      migration_content = <<~RUBY
        class CreateKnitsearchesMultisearch < ActiveRecord::Migration#{migration_version}
          include Knitsearch::Migration

          def up
            create_multisearch_table
          end

          def down
            drop_multisearch_table
          end
        end
      RUBY

      create_file migration_path, migration_content

      puts "\nMigration created: #{migration_path}"
      puts "\nNext steps:"
      puts "  1. bin/rails db:migrate"
      puts "  2. Add `multisearchable against: [:column1, :column2]` to your models"
      puts "  3. Run backfill for existing records: Model.knitsearch_multisearch_backfill!"
    end

    no_tasks do
      def migration_version
        "[#{::Rails::VERSION::MAJOR}.#{::Rails::VERSION::MINOR}]"
      end

      def table_exists?(table_name)
        ::ActiveRecord::Base.connection.table_exists?(table_name)
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
