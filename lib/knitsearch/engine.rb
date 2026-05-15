# frozen_string_literal: true

require "rails/engine"

module Knitsearch
  class Engine < ::Rails::Engine
    initializer "knitsearch.schema_dumper_ignore_tables" do
      ActiveSupport.on_load(:active_record) do
        pattern = /(_fts|_fts_data|_fts_idx|_fts_content|_fts_docsize|_fts_config|_fts_vocab)$/
        unless ActiveRecord::SchemaDumper.ignore_tables.include?(pattern)
          ActiveRecord::SchemaDumper.ignore_tables << pattern
        end
      end
    end

    initializer "knitsearch.hook_multisearchable" do
      ActiveSupport.on_load(:active_record) do
        include Knitsearch::Multisearchable
      end
    end
  end
end
