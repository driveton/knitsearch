# frozen_string_literal: true

require "active_support/concern"

module Knitsearch
  module MultisearchableSync
    extend ActiveSupport::Concern

    included do
      # Proc form, not symbol form. Symbol-form after_commit callbacks silently no-op when
      # the target method is defined on a module included into the class — the callback registers
      # but dispatch never reaches the method. Procs work.
      after_save_commit   { |record| record.knitsearch_sync_document }
      after_destroy_commit { |record| record.knitsearch_destroy_document }
    end

    def knitsearch_sync_document
      content = self.class.atomic_multisearchable_columns
                  .map { |col| send(col).to_s }
                  .reject(&:empty?)
                  .join(" ")

      doc = Knitsearch::Document.find_or_initialize_by(
        searchable_type: self.class.name,
        searchable_id:   id
      )
      doc.content = content
      doc.save!
    end

    def knitsearch_destroy_document
      Knitsearch::Document.where(
        searchable_type: self.class.name,
        searchable_id:   id
      ).delete_all
    end
  end
end
