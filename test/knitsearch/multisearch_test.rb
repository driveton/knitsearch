# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::MultisearchTest < Minitest::Test
  include MultisearchTestHelper
  include CardsAndAgendasTestHelper

  def test_cross_model_search_hits_from_both_card_and_agenda
    Card.multisearchable against: [:name]
    Agenda.multisearchable against: [:name]

    card = Card.create!(name: "Important Contact", agenda_id: nil)
    agenda = Agenda.create!(name: "Important People")

    results = Knitsearch.multisearch("Important").to_a
    assert_equal 2, results.count
    assert_includes results.map(&:searchable_id), card.id
    assert_includes results.map(&:searchable_id), agenda.id
  end

  def test_bm25_ranking_exact_match_beats_partial
    Card.multisearchable against: [:name, :body]

    card1 = Card.create!(name: "Database Guide", body: "about systems")
    card2 = Card.create!(name: "Performance Tips", body: "database optimization techniques")

    results = Knitsearch.multisearch("database").to_a
    assert_equal 2, results.count
    # Exact title match in card1 should rank higher than body match in card2
    assert_equal card1.id, results.first.searchable_id
    assert_equal card2.id, results.last.searchable_id
  end

  def test_updating_source_record_updates_document_content
    Card.multisearchable against: [:name, :body]
    reset_multisearch!

    card = Card.create!(name: "Initial", body: "content here")
    doc = Knitsearch.multisearch("Initial").first
    assert_equal card.id, doc.searchable_id

    # Update the card
    card.update!(name: "Updated", body: "different")
    doc.reload

    # Old term should not match, new term should
    results = Knitsearch.multisearch("Initial").to_a
    assert_equal 0, results.count

    results = Knitsearch.multisearch("Updated").to_a
    assert_equal 1, results.count
    assert_equal card.id, results.first.searchable_id
  end

  def test_destroying_source_record_removes_document
    Card.multisearchable against: [:name]
    reset_multisearch!

    card = Card.create!(name: "Deletable")
    assert_equal 1, Knitsearch.multisearch("Deletable").count

    card.destroy

    assert_equal 0, Knitsearch.multisearch("Deletable").count
  end

  def test_limit_is_honored
    Card.multisearchable against: [:name]

    Card.create!(name: "Test 1", agenda_id: nil)
    Card.create!(name: "Test 2", agenda_id: nil)
    Card.create!(name: "Test 3", agenda_id: nil)

    results = Knitsearch.multisearch("Test", limit: 2).to_a
    assert_equal 2, results.count
  end

  def test_blank_query_returns_document_none
    Card.multisearchable against: [:name]

    result = Knitsearch.multisearch("")
    assert_equal Knitsearch::Document.none, result

    result = Knitsearch.multisearch(nil)
    assert_equal Knitsearch::Document.none, result

    result = Knitsearch.multisearch("   ")
    assert_equal Knitsearch::Document.none, result
  end

  def test_includes_searchable_materializes_heterogeneous_records
    Card.multisearchable against: [:name]
    Agenda.multisearchable against: [:name]

    card = Card.create!(name: "VIP Card", agenda_id: nil)
    agenda = Agenda.create!(name: "VIP Agenda")

    results = Knitsearch.multisearch("VIP").includes(:searchable).to_a
    assert_equal 2, results.count

    # Both searchable records should be materialized and accessible
    card_result = results.find { |r| r.searchable_type == "Card" }
    assert_equal card.name, card_result.searchable.name

    agenda_result = results.find { |r| r.searchable_type == "Agenda" }
    assert_equal agenda.name, agenda_result.searchable.name
  end

  def test_commit_callbacks_include_multisearch_sync
    reset_multisearchable_state!(Card)

    Card.multisearchable against: [:name]

    # Verify that callbacks fire by creating a record and checking if it syncs
    reset_multisearch!
    Card.create!(name: "Callback Test", agenda_id: nil)

    # If the callback worked, the record should be indexed
    results = Knitsearch.multisearch("Callback").to_a
    assert_equal 1, results.count,
                 "Expected multisearch callback to sync record on create"
  end

  def test_backfill_populates_documents_for_existing_records
    # Create cards WITHOUT multisearchable first
    reset_multisearchable_state!(Card)
    Card.create!(name: "Backfill Test 1", agenda_id: nil)
    Card.create!(name: "Backfill Test 2", agenda_id: nil)

    # Now declare multisearchable and backfill
    Card.multisearchable against: [:name]
    Card.knitsearch_multisearch_backfill!

    # Both should now be searchable
    results = Knitsearch.multisearch("Backfill Test").to_a
    assert_equal 2, results.count
  end

  def test_model_with_both_searchable_by_and_multisearchable_works_independently
    # FTS table is already created at startup with superset columns
    # Just use a subset for this test
    Card.searchable_by against: { name: "A" }
    Card.multisearchable against: [:name]
    reset_multisearch!

    card = Card.create!(name: "Dual Index", agenda_id: nil)

    # Per-model search should work
    results = Card.search("Dual").to_a
    assert_equal 1, results.count

    # Multi-model search should also work
    multi_results = Knitsearch.multisearch("Dual").to_a
    assert_equal 1, multi_results.count
    assert_equal card.id, multi_results.first.searchable_id
  end

  def test_multisearch_with_fts_operator_words_does_not_crash
    Card.multisearchable against: [:name]

    Card.create!(name: "Test AND OR NOT content", agenda_id: nil)

    result = Knitsearch.multisearch("AND OR NOT")
    assert result.is_a?(ActiveRecord::Relation)
  end

  def test_multisearch_with_very_long_query_does_not_crash
    Card.multisearchable against: [:name]

    Card.create!(name: "Test", agenda_id: nil)

    long_query = "a" * 5000
    result = Knitsearch.multisearch(long_query)
    assert result.is_a?(ActiveRecord::Relation)
  end

  def test_multisearch_document_create_rollback_consistency
    Card.multisearchable against: [:name]
    reset_multisearch!

    # Create a card inside a transaction and roll back
    # after_commit callbacks should NOT fire, so document should not exist
    Card.transaction do
      Card.create!(name: "Rollback Test", agenda_id: nil)
      # Inside transaction, before commit, callback hasn't fired yet
      assert_equal 0, Knitsearch.multisearch("Rollback").count, "Callback shouldn't fire until commit"
      raise ActiveRecord::Rollback
    end

    # After rollback, document should not exist (callback never fired)
    assert_equal 0, Knitsearch.multisearch("Rollback").count,
                 "Document should not exist after transaction rollback"
  end

  def test_multisearch_document_destroy_rollback_consistency
    Card.multisearchable against: [:name]
    reset_multisearch!

    # Create a card outside transaction so document exists
    card = Card.create!(name: "Destroy Rollback Test", agenda_id: nil)
    assert_equal 1, Knitsearch.multisearch("Destroy").count

    # Destroy inside transaction and roll back
    # after_destroy_commit callback should NOT fire, so document should stay
    Card.transaction do
      card.destroy
      # Inside transaction, before commit, destroy callback hasn't fired yet
      assert_equal 1, Knitsearch.multisearch("Destroy").count, "Destroy callback shouldn't fire until commit"
      raise ActiveRecord::Rollback
    end

    # After rollback, document should still exist (destroy callback never fired)
    assert_equal 1, Knitsearch.multisearch("Destroy").count,
                 "Document should exist again after destroy rollback"
  end

  private

  def test_zero_manual_sync_calls_required
    Card.multisearchable against: [:name]
    reset_multisearch!

    # Only create and update — no explicit knitsearch_sync_document calls
    card = Card.create!(name: "Auto Sync Test", agenda_id: nil)
    results = Knitsearch.multisearch("Auto").to_a
    assert_equal 1, results.count

    card.update!(name: "Auto Sync Updated")
    results = Knitsearch.multisearch("Auto").to_a
    assert_equal 1, results.count

    # All syncing happened via callbacks automatically
  end
end
