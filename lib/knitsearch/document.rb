# frozen_string_literal: true

module Knitsearch
  class Document < ActiveRecord::Base
    self.table_name = "knitsearches"
    belongs_to :searchable, polymorphic: true

    def self.backfill!(model_class)
      model_class.find_each(&:knitsearch_sync_document)
    end
  end
end
