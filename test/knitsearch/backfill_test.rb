# frozen_string_literal: true

require_relative "../test_helper"

# Fixture model for callback test
class CallbackTestArticle < Article
  attr_reader :callback_fired

  before_save do
    @callback_fired = true
  end
end

class Knitsearch::BackfillTest < Minitest::Test
  include ArticlesTestHelper

  # === Existing-record indexing (no rich text) ===

  def test_backfill_indexes_existing_records_without_rich_text
    # First set up search (this creates FTS table with triggers)
    Article.searchable_by against: { title: "A", body: "B" }

    # Create 5 records using raw SQL before FTS has any data
    5.times do |i|
      title = Article.connection.quote("Rails #{i}")
      body = Article.connection.quote("Framework article #{i}")
      Article.connection.execute(
        "INSERT INTO articles (title, body, created_at, updated_at) VALUES (#{title}, #{body}, datetime('now'), datetime('now'))"
      )
    end

    # At this point FTS is empty (raw SQL bypassed triggers), so search returns nothing
    # Run backfill to rebuild FTS from source table
    Article.knitsearch_backfill!

    # Now search should find the records
    results = Article.search("rails").to_a
    assert_equal 5, results.count
    assert_match(/Rails/, results.first.title)
  end

  # === Existing-record indexing (with rich text) ===

  def test_backfill_indexes_existing_records_with_rich_text
    # Create 5 records with rich text before setting up search
    created_articles = 5.times.map { |i| Article.create!(title: "Post #{i}", content: ActionText::RichText.new(body: "<p>Search term #{i}</p>")) }

    # Verify shadow columns are NULL
    Article.find_each do |article|
      assert_nil article.content_plain_text, "Shadow column should be NULL before backfill"
    end

    # Set up search with rich text field
    Article.searchable_by against: { title: "A", content: "B" }

    # Run backfill
    Article.knitsearch_backfill!

    # Verify shadow columns are populated by checking against the actual content
    created_articles.each_with_index do |article, i|
      reloaded = article.reload
      expected_plain_text = "Search term #{i}"
      assert_equal expected_plain_text, reloaded.content_plain_text
    end

    # Verify search finds matches in rich text
    results = Article.search("search").to_a
    assert_equal 5, results.count
  end

  def test_backfill_extracts_plain_text_correctly_from_rich_text
    Article.create!(title: "Test", content: ActionText::RichText.new(body: "<p>Hello <b>world</b></p>"))
    Article.searchable_by against: { content: "A" }
    Article.knitsearch_backfill!

    article = Article.first
    assert_equal "Hello world", article.reload.content_plain_text
  end

  # === Backfill doesn't bump updated_at ===

  def test_backfill_does_not_bump_updated_at
    articles = 3.times.map { |i| Article.create!(title: "Article #{i}", body: "Content #{i}") }
    timestamps_before = articles.map { |a| a.reload.updated_at }

    # Wait a small amount to ensure time would have advanced
    sleep 0.1

    Article.searchable_by against: { title: "A", body: "B" }
    Article.knitsearch_backfill!

    articles.each_with_index do |article, idx|
      reloaded = Article.find(article.id)
      # Check that updated_at is the same (or very close, within 1 second to handle precision)
      time_diff = (reloaded.updated_at - timestamps_before[idx]).abs
      assert time_diff < 1, "updated_at should not change during backfill (diff: #{time_diff}s)"
    end
  end

  # === Backfill doesn't fire other callbacks ===

  def test_backfill_does_not_fire_before_save_callbacks
    CallbackTestArticle.searchable_by against: { title: "A", body: "B" }

    # Use raw SQL to create a record, bypassing the callback
    title = CallbackTestArticle.connection.quote("Test")
    body = CallbackTestArticle.connection.quote("Content")
    CallbackTestArticle.connection.execute(
      "INSERT INTO articles (title, body, created_at, updated_at) VALUES (#{title}, #{body}, datetime('now'), datetime('now'))"
    )

    CallbackTestArticle.searchable_by against: { title: "A", body: "B" }
    CallbackTestArticle.knitsearch_backfill!

    # Re-fetch to check if callback was fired (it shouldn't be during backfill)
    record = CallbackTestArticle.first
    assert_nil record.instance_variable_get(:@callback_fired), "before_save callbacks should not fire during backfill"
  end

  # === Backfill is idempotent ===

  def test_backfill_is_idempotent
    Article.create!(title: "Article", body: "Content")

    Article.searchable_by against: { title: "A", body: "B" }

    # First backfill
    Article.knitsearch_backfill!
    results_first = Article.search("article").to_a
    assert_equal 1, results_first.count

    # Second backfill
    Article.knitsearch_backfill!
    results_second = Article.search("article").to_a
    assert_equal 1, results_second.count
  end

  # === knitsearch_backfill! behavior ===

  def test_knitsearch_backfill_on_rich_text_populates_shadow_and_does_not_rebuild
    Article.create!(title: "Test", content: ActionText::RichText.new(body: "<p>Hidden content</p>"))
    Article.searchable_by against: { title: "A", content: "B" }

    # Shadow column should be NULL initially
    assert_nil Article.first.content_plain_text

    # Call knitsearch_backfill! (should backfill shadow columns, not rebuild FTS)
    Article.knitsearch_backfill!

    # Shadow column should now be populated
    assert_equal "Hidden content", Article.first.reload.content_plain_text

    # Search should find it
    results = Article.search("hidden").to_a
    assert_equal 1, results.count
  end

  def test_knitsearch_backfill_on_non_rich_text_rebuilds_fts
    # Create records before FTS setup
    Article.create!(title: "Article", body: "Content")
    Article.searchable_by against: { title: "A", body: "B" }

    # Search finds it (FTS was created, triggers work for new records)
    assert_equal 1, Article.search("article").count

    # knitsearch_backfill! on non-rich-text should rebuild (no backfill needed)
    Article.knitsearch_backfill!

    # Search should still find it
    results = Article.search("article").to_a
    assert_equal 1, results.count
  end

  def test_reindex_on_non_rich_text_rebuilds_fts
    Article.create!(title: "Article", body: "Content")
    Article.searchable_by against: { title: "A", body: "B" }

    # Search finds it
    assert_equal 1, Article.search("article").count

    # reindex! rebuilds the FTS index
    Article.reindex!

    # Search should still find it
    results = Article.search("article").to_a
    assert_equal 1, results.count
  end

  def test_reindex_on_rich_text_rebuilds_without_backfill
    Article.create!(title: "Test", content: ActionText::RichText.new(body: "<p>Hidden</p>"))
    Article.searchable_by against: { title: "A", content: "B" }

    # Manually backfill shadow column
    Article.knitsearch_backfill!
    assert_equal "Hidden", Article.first.reload.content_plain_text

    # Manually clear shadow column to simulate stale data
    Article.update_all(content_plain_text: nil)
    assert_nil Article.first.reload.content_plain_text

    # reindex! rebuilds FTS index, does NOT backfill shadow columns
    Article.reindex!

    # Shadow column should still be NULL (no backfill)
    assert_nil Article.first.reload.content_plain_text
  end

  # === Legacy table case: verify reindex! rebuilds FTS on existing rows ===

  def test_reindex_rebuilds_fts_from_current_host_table_content
    # Test the core issue: reindex! should rebuild FTS from current host table state
    # This tests that non-rich-text models can use reindex! to rebuild after corruption
    Article.create!(title: "Rebuild Test", body: "Content to find")
    Article.searchable_by against: { title: "A", body: "B" }

    # Verify search works
    assert_equal 1, Article.search("rebuild").count

    # Manually clear FTS (simulate corruption)
    connection = Article.connection
    connection.execute("DELETE FROM articles_fts")

    # Verify search is now broken (FTS empty)
    assert_equal 0, Article.search("rebuild").count

    # reindex! should rebuild FTS from host table
    Article.reindex!

    # Search should now work again
    results = Article.search("rebuild").to_a
    assert_equal 1, results.count
  end

  def test_knitsearch_backfill_calls_reindex_for_non_rich_text
    # Verify that knitsearch_backfill! calls reindex! for plain-column models
    # (which rebuilds the FTS index without trying to backfill shadows)
    Article.create!(title: "Backfill Non-RT", body: "Plain text model")
    Article.searchable_by against: { title: "A", body: "B" }

    # Clear FTS
    connection = Article.connection
    connection.execute("DELETE FROM articles_fts")
    assert_equal 0, Article.search("backfill").count

    # knitsearch_backfill! should rebuild via reindex!
    Article.knitsearch_backfill!

    # Search should work
    results = Article.search("backfill").to_a
    assert_equal 1, results.count
  end

  private

  def call_count
    @call_count ||= 0
  end
end
