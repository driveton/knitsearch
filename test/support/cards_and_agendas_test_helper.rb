# frozen_string_literal: true

module CardsAndAgendasTestHelper
  extend ActiveSupport::Concern

  def setup
    super
    reset_cards_and_agendas!
    reset_card_and_agenda_state!
  end

  def teardown
    super
  end

  private
    def reset_card_and_agenda_state!
      [Card, Agenda, CardTag, Tag].each do |model|
        model.instance_variable_set(:@rich_text_mapping, {})
        model.instance_variable_set(:@associated_mapping, {})
        model.instance_variable_set(:@searchable_columns, nil)
        model.instance_variable_set(:@searchable_options, nil)
        model.instance_variable_set(:@searchable_dictionary, nil)
        model.instance_variable_set(:@atomic_multisearchable_columns, nil)
        if model.respond_to?(:knitsearch_callbacks_installed=)
          model.knitsearch_callbacks_installed = false
        else
          model.instance_variable_set(:@knitsearch_callbacks_installed, false)
        end
        model.remove_instance_variable(:@knitsearch_dependents_installed) if model.instance_variable_defined?(:@knitsearch_dependents_installed)
      end

      Knitsearch.instance_variable_set(:@belongs_to_dependents, nil)
      Knitsearch.instance_variable_set(:@has_many_dependents, nil)
      Knitsearch.instance_variable_set(:@has_many_through_dependents, nil)
      Knitsearch.instance_variable_set(:@has_many_through_target_dependents, nil)
    end

    def reset_cards_and_agendas!
      CardTag.delete_all
      Tag.delete_all
      Card.delete_all
      Agenda.delete_all
      ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name = 'cards'") rescue nil
      ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name = 'agendas'") rescue nil
      ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name = 'tags'") rescue nil
      ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name = 'card_tags'") rescue nil
    end
end
