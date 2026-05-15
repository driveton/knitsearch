# frozen_string_literal: true

require "active_support/concern"

module Knitsearch
  module HasManyDependent
    extend ActiveSupport::Concern

    included do
      # Proc form, not `after_save_commit :knitsearch_refresh_has_many_parents`.
      # Symbol-form after_commit callbacks silently no-op when the target method
      # is defined on a module included into the class — the callback registers
      # but dispatch never reaches the method. Procs work.
      after_save_commit { |record| record.knitsearch_refresh_has_many_parents }
      after_destroy_commit { |record| record.knitsearch_refresh_has_many_parents }
    end

    def knitsearch_refresh_has_many_parents
      dependents = Knitsearch.has_many_dependents[self.class]
      return unless dependents

      dependents.each do |dependent|
        parent_class = dependent[:parent]
        inverse_fk_sym = dependent[:inverse_fk]
        shadow_map = dependent[:columns]
        parent_assoc = dependent[:parent_assoc]

        # Determine which parents to update
        parents_to_update = []

        # Current parent (if FK is set)
        current_fk_value = read_attribute(inverse_fk_sym)
        if current_fk_value.present?
          parents_to_update << current_fk_value
        end

        # Previous parent (if FK was changed)
        if saved_change_to_attribute?(inverse_fk_sym)
          old_fk_value = saved_changes[inverse_fk_sym]&.first
          if old_fk_value.present?
            parents_to_update << old_fk_value
          end
        end

        # Update each affected parent
        parents_to_update.uniq.each do |parent_id|
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
