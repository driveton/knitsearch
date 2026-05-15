# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::AssociatedAgainstHasManyTest < Minitest::Test
  include CardsAndAgendasTestHelper

  def setup
    super
  end

  def test_parent_with_no_children_has_nil_shadow_column
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }
    agenda = Agenda.create!(name: "Empty Agenda")

    assert_nil agenda.reload.cards_name_plain_text
  end

  def test_adding_child_populates_parent_shadow_column
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }
    agenda = Agenda.create!(name: "My Agenda")
    Card.create!(name: "John Doe", agenda: agenda)

    assert_equal "John Doe", agenda.reload.cards_name_plain_text
  end

  def test_multiple_children_concatenated_space_separated
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }
    agenda = Agenda.create!(name: "Prospects")

    Card.create!(name: "Alice", agenda: agenda)
    Card.create!(name: "Bob", agenda: agenda)
    Card.create!(name: "Charlie", agenda: agenda)

    assert_equal "Alice Bob Charlie", agenda.reload.cards_name_plain_text
  end

  def test_updating_child_refreshes_parent_shadow_column
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }
    agenda = Agenda.create!(name: "Agenda")
    card = Card.create!(name: "Old Name", agenda: agenda)

    assert_equal "Old Name", agenda.reload.cards_name_plain_text

    card.update!(name: "New Name")
    assert_equal "New Name", agenda.reload.cards_name_plain_text
  end

  def test_destroying_child_removes_from_shadow_column
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }
    agenda = Agenda.create!(name: "Agenda")
    card1 = Card.create!(name: "Alice", agenda: agenda)
    card2 = Card.create!(name: "Bob", agenda: agenda)

    assert_equal "Alice Bob", agenda.reload.cards_name_plain_text

    card1.destroy
    assert_equal "Bob", agenda.reload.cards_name_plain_text
  end

  def test_reassigning_child_updates_both_parents
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }
    agenda1 = Agenda.create!(name: "Agenda 1")
    agenda2 = Agenda.create!(name: "Agenda 2")
    card = Card.create!(name: "John", agenda: agenda1)

    assert_equal "John", agenda1.reload.cards_name_plain_text
    assert_nil agenda2.reload.cards_name_plain_text

    card.update!(agenda: agenda2)

    assert_nil agenda1.reload.cards_name_plain_text
    assert_equal "John", agenda2.reload.cards_name_plain_text
  end

  def test_child_save_without_triggering_parent_callbacks
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }

    callback_count = 0
    Agenda.before_save { callback_count += 1 }

    agenda = Agenda.create!(name: "Agenda")
    Card.create!(name: "Card", agenda: agenda)

    # Callback was called for agenda creation only (1), not for card creation
    assert_equal 1, callback_count
  end

  def test_empty_child_values_excluded_from_concatenation
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }
    agenda = Agenda.create!(name: "Agenda")

    Card.create!(name: "Alice", agenda: agenda)
    Card.create!(name: nil, agenda: agenda)  # nil should be skipped
    Card.create!(name: "Bob", agenda: agenda)

    assert_equal "Alice Bob", agenda.reload.cards_name_plain_text
  end

  def test_child_after_save_commit_callback_installed
    Agenda.searchable_by against: { name: "A" }, associated_against: { cards: [:name] }

    # Verify callbacks are installed on Card (as Procs from the Concern)
    assert Card._commit_callbacks.any? { |cb| cb.filter.is_a?(Proc) }
  end
end
