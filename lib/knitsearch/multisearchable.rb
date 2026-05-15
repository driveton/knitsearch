# frozen_string_literal: true

require "active_support/concern"

module Knitsearch
  module Multisearchable
    extend ActiveSupport::Concern

    class_methods do
      def multisearchable(against:)
        @atomic_multisearchable_columns = Array(against).map(&:to_sym)
        include Knitsearch::MultisearchableSync unless include?(Knitsearch::MultisearchableSync)
      end

      def atomic_multisearchable_columns
        @atomic_multisearchable_columns || []
      end

      def knitsearch_multisearch_backfill!
        Knitsearch::Document.backfill!(self)
      end
    end
  end
end
