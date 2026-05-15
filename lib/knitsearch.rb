# frozen_string_literal: true

require "active_support"

require "knitsearch/version"
require "knitsearch/engine"
require "knitsearch/has_many_dependent"
require "knitsearch/has_many_through_join_dependent"
require "knitsearch/has_many_through_target_dependent"
require "knitsearch/document"
require "knitsearch/multisearchable"
require "knitsearch/multisearchable_sync"

require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.ignore("#{__dir__}/generators")
loader.setup

module Knitsearch
  TOKENIZER_PRESETS = {
    unicode: "unicode61 remove_diacritics 2",
    ascii: "ascii",
    porter: "porter",
    trigram: "trigram"
  }.freeze

  WEIGHT_BUCKETS = {
    "A" => 8,
    "B" => 4,
    "C" => 2,
    "D" => 1
  }.freeze

  SUPPORTED_DICTIONARIES = %w[simple english trigram].freeze

  class Error < StandardError; end
  class SchemaMismatchError < Error; end
  class ColumnError < Error; end
  class UnknownDictionaryError < Error; end
  class ConfigurationError < Error; end

  class << self
    attr_reader :belongs_to_dependents, :has_many_dependents, :has_many_through_dependents, :has_many_through_target_dependents

    def belongs_to_dependents
      @belongs_to_dependents ||= Hash.new { |h, k| h[k] = [] }
    end

    def has_many_dependents
      @has_many_dependents ||= Hash.new { |h, k| h[k] = [] }
    end

    def has_many_through_dependents
      @has_many_through_dependents ||= Hash.new { |h, k| h[k] = [] }
    end

    def has_many_through_target_dependents
      @has_many_through_target_dependents ||= Hash.new { |h, k| h[k] = [] }
    end

    def multisearch(query, limit: nil)
      return Document.none if query.blank?

      escaped = Knitsearch::Query.escape(query, operator: :and, prefix: false, match: :word)
      return Document.none if escaped.nil?

      relation = Document
        .joins("INNER JOIN knitsearches_fts ON knitsearches_fts.rowid = knitsearches.id")
        .where("knitsearches_fts MATCH ?", escaped)
        .order(Arel.sql("bm25(knitsearches_fts)"))

      limit ? relation.limit(limit) : relation
    end

    def register_belongs_to_dependent(parent_class, child_class, foreign_key, shadow_map)
      belongs_to_dependents[parent_class] << {
        model: child_class,
        foreign_key: foreign_key,
        columns: shadow_map
      }

      # Install after_update_commit hook on parent class (idempotent)
      unless parent_class.instance_variable_defined?(:@knitsearch_dependents_installed)
        parent_class.instance_variable_set(:@knitsearch_dependents_installed, true)
        parent_class.after_update_commit :knitsearch_cascade_to_children
      end
    end

    def register_has_many_dependent(child_class, parent_class, inverse_fk, shadow_map, parent_assoc)
      has_many_dependents[child_class] << {
        parent: parent_class,
        inverse_fk: inverse_fk,
        columns: shadow_map,
        parent_assoc: parent_assoc
      }

      child_class.include(HasManyDependent) unless child_class.include?(HasManyDependent)
    end

    def register_has_many_through_dependent(join_class:, target_class:, parent_class:, parent_fk:, target_fk:, parent_assoc:, shadow_map:)
      # Store on join class side (for join create/destroy callbacks)
      has_many_through_dependents[join_class] << {
        parent_class: parent_class,
        parent_fk: parent_fk,
        target_class: target_class,
        target_fk: target_fk,
        parent_assoc: parent_assoc,
        columns: shadow_map
      }

      # Store on target class side (for target update callbacks)
      source_columns = shadow_map.values
      has_many_through_target_dependents[target_class] << {
        join_class: join_class,
        parent_class: parent_class,
        parent_fk: parent_fk,
        target_fk: target_fk,
        parent_assoc: parent_assoc,
        columns: shadow_map,
        source_columns: source_columns
      }

      # Install callbacks on both join and target classes
      join_class.include(HasManyThroughJoinDependent) unless join_class.include?(HasManyThroughJoinDependent)
      target_class.include(HasManyThroughTargetDependent) unless target_class.include?(HasManyThroughTargetDependent)
    end
  end
end
