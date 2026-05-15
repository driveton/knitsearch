# frozen_string_literal: true

require "active_support/concern"

module Knitsearch
  module HasManyThroughTargetDependent
    extend ActiveSupport::Concern

    included do
      # Proc form, not `after_update_commit :knitsearch_refresh_through_parents_from_target`.
      # Symbol-form after_commit callbacks silently no-op when the target method
      # is defined on a module included into the class — the callback registers
      # but dispatch never reaches the method. Procs work.
      after_update_commit { |record| record.knitsearch_refresh_through_parents_from_target }
    end

    def knitsearch_refresh_through_parents_from_target
      dependents = Knitsearch.has_many_through_target_dependents[self.class]
      return unless dependents

      dependents.each do |dependent|
        join_class = dependent[:join_class]
        parent_class = dependent[:parent_class]
        parent_fk = dependent[:parent_fk]
        target_fk = dependent[:target_fk]
        parent_assoc = dependent[:parent_assoc]
        shadow_map = dependent[:columns]
        source_columns = dependent[:source_columns]

        # Guard: only refresh if any indexed source column actually changed
        changed_indexed_columns = saved_changes.keys.map(&:to_sym) & source_columns.map(&:to_sym)
        return if changed_indexed_columns.empty?

        # Find all parent IDs that have this target through any join row
        parent_ids = join_class.where(target_fk => id).pluck(parent_fk).uniq

        # Refresh each affected parent
        parent_ids.each do |parent_id|
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
end
