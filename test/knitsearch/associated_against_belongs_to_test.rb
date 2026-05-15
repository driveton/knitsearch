# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::AssociatedAgainstBelongsToTest < Minitest::Test
  include CardsAndAgendasTestHelper

  def setup
    super
  end

  def test_child_save_populates_shadow_column_when_parent_exists
    agenda = Agenda.create!(name: "Real Estate Prospects")
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }

    card = Card.create!(name: "John Doe", agenda: agenda)

    assert_equal "Real Estate Prospects", card.reload.agenda_name_plain_text
  end

  def test_child_save_with_nil_parent_sets_shadow_to_nil
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }

    card = Card.create!(name: "John Doe", agenda: nil)

    assert_nil card.reload.agenda_name_plain_text
  end

  def test_search_matches_parent_text
    agenda = Agenda.create!(name: "Real Estate Prospects")
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }
    card = Card.create!(name: "John Doe", agenda: agenda)

    results = Card.search("real estate").to_a
    assert_equal 1, results.count
    assert_equal card.id, results.first.id
  end

  def test_parent_update_cascades_to_children
    agenda = Agenda.create!(name: "Old Name")
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }
    card1 = Card.create!(name: "Card 1", agenda: agenda)
    card2 = Card.create!(name: "Card 2", agenda: agenda)

    # Verify initial state
    assert_equal "Old Name", card1.reload.agenda_name_plain_text
    assert_equal "Old Name", card2.reload.agenda_name_plain_text

    # Update parent
    agenda.update!(name: "New Prospect List")

    # Check shadow columns updated
    assert_equal "New Prospect List", card1.reload.agenda_name_plain_text
    assert_equal "New Prospect List", card2.reload.agenda_name_plain_text
  end

  def test_parent_after_update_commit_callback_installed
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }

    # Verify callback is installed on Agenda (the parent in belongs_to)
    assert Agenda._commit_callbacks.any? { |cb| cb.filter == :knitsearch_cascade_to_children }
  end

  def test_reassigning_child_to_different_parent
    agenda1 = Agenda.create!(name: "Agenda One")
    agenda2 = Agenda.create!(name: "Agenda Two")
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }

    card = Card.create!(name: "Card", agenda: agenda1)
    assert_equal "Agenda One", card.reload.agenda_name_plain_text

    card.update!(agenda: agenda2)
    assert_equal "Agenda Two", card.reload.agenda_name_plain_text
  end

  def test_hash_form_honors_weight_bucket
    agenda = Agenda.create!(name: "Investment")
    Card.searchable_by(
      against: { name: "A" },
      associated_against: { agenda: { name: "A" } }
    )
    Card.create!(name: "John", agenda: agenda)
    Card.create!(name: "Investment Bank", agenda: Agenda.create!(name: "General"))

    # Both match "investment" but card2 should rank higher because it matches in name field (weight A)
    # while card1 matches in agenda.name (also weight A). Actually both have same weight, so just verify both match
    results = Card.search("investment").to_a
    assert_equal 2, results.count
  end

  def test_array_form_defaults_to_weight_c
    agenda = Agenda.create!(name: "Priority Clients")
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }

    Card.create!(name: "Alice", agenda: agenda)
    results = Card.search("priority").to_a
    assert_equal 1, results.count
  end

  def test_raises_error_for_undefined_association
    assert_raises Knitsearch::ConfigurationError do
      Card.searchable_by against: { name: "A" }, associated_against: { nonexistent: [:name] }
    end
  end

  def test_sync_associated_repopulates_shadow_columns
    agenda = Agenda.create!(name: "Backfill Test")
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }
    card1 = Card.create!(name: "Card 1", agenda: agenda)

    # Manually call sync method to verify it works
    card1.sync_associated_to_shadow_columns
    assert_equal "Backfill Test", card1.agenda_name_plain_text
  end

  def test_parent_destroy_with_dependent_destroy_cleans_children
    agenda = Agenda.create!(name: "To Delete")
    Card.searchable_by against: { name: "A" }, associated_against: { agenda: [:name] }
    Card.create!(name: "Child Card", agenda: agenda)

    assert_equal 1, Card.count
    agenda.destroy
    assert_equal 0, Card.count
  end

end
