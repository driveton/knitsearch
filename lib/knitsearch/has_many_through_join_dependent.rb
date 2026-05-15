# frozen_string_literal: true

require "active_support/concern"

module Knitsearch
  module HasManyThroughJoinDependent
    extend ActiveSupport::Concern

    included do
      # Proc form, not `after_save_commit :knitsearch_refresh_through_parent_from_join`.
      # Symbol-form after_commit callbacks silently no-op when the target method
      # is defined on a module included into the class — the callback registers
      # but dispatch never reaches the method. Procs work.
      after_create_commit { |record| record.knitsearch_refresh_through_parent_from_join }
      after_destroy_commit { |record| record.knitsearch_refresh_through_parent_from_join }
    end

    def knitsearch_refresh_through_parent_from_join
      dependents = Knitsearch.has_many_through_dependents[self.class]
      return unless dependents

      dependents.each do |dependent|
        parent_class = dependent[:parent_class]
        parent_fk = dependent[:parent_fk]
        parent_assoc = dependent[:parent_assoc]
        shadow_map = dependent[:columns]

        # Read the parent FK from the join row
        parent_id = read_attribute(parent_fk)
        next unless parent_id.present?

        # Find the parent and refresh its shadow columns
        parent = parent_class.find_by(id: parent_id)
        next unless parent

        # Recompute shadow columns for this parent
        updates = {}
        shadow_map.each do |shadow_col, source_col|
          values = parent.send(parent_assoc).pluck(source_col).compact.map(&:to_s)
          updates[shadow_col] = values.any? ? values.join(" ") : nil
        end

        parent.update_columns(updates)
      end
    end
  end
end
