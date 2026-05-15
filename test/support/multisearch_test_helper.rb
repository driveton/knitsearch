# frozen_string_literal: true

module MultisearchTestHelper
  extend ActiveSupport::Concern

  def setup
    super
    reset_multisearch!
    reset_multisearchable_state!(Article, Card, Agenda)
  end

  def teardown
    super
  end

  private
    def reset_multisearch!
      Knitsearch::Document.delete_all
    end

    def reset_multisearchable_state!(*models)
      models.each do |model|
        model.instance_variable_set(:@knitsearch_multisearchable_columns, nil)
      end
    end
end
