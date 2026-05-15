# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::DictionaryTest < Minitest::Test
  include ArticlesTestHelper

  def setup
    super
    reset_english_article_state!
    EnglishArticle.delete_all
  end

  # === Simple (default) — no stemming ===

  def test_simple_dictionary_default_no_stemming
    Article.searchable_by against: { title: "A", body: "B" }

    assert_equal "simple", Article.searchable_dictionary
    Article.create!(title: "Running fast", body: "She runs")

    # Without stemming, "run" should NOT match "running" or "runs"
    assert_equal 0, Article.search("run").count
    assert_equal 1, Article.search("running").count
    assert_equal 1, Article.search("runs").count
  end

  def test_simple_dictionary_explicit
    Article.searchable_by against: { title: "A", body: "B" },
                          using: { fts5: { dictionary: "simple" } }

    assert_equal "simple", Article.searchable_dictionary
    Article.create!(title: "Running fast", body: "She runs")

    assert_equal 0, Article.search("run").count
  end

  # === English — FTS5 porter stemmer ===

  def test_english_dictionary_stems_via_fts5_porter
    EnglishArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "english" } }

    assert_equal "english", EnglishArticle.searchable_dictionary
    EnglishArticle.create!(title: "Running fast", body: "She runs")

    # With English stemming, "run" matches both "running" and "runs"
    assert_equal 1, EnglishArticle.search("run").count
  end

  def test_english_stemming_in_title_and_body
    EnglishArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "english" } }

    EnglishArticle.create!(title: "Running", body: "No match")
    EnglishArticle.create!(title: "No match", body: "running")

    # Both match "run"
    results = EnglishArticle.search("run").to_a
    assert_equal 2, results.count
  end

  def test_english_dictionary_with_weights
    EnglishArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "english" } }

    EnglishArticle.create!(title: "Running", body: "Other content")
    EnglishArticle.create!(title: "Other content", body: "running")

    # A-weight (title) should rank higher than B-weight (body)
    results = EnglishArticle.search("run").to_a
    assert_equal 2, results.count
    assert_equal "Running", results.first.title
  end

  def test_english_with_prefix_matching
    EnglishArticle.searchable_by against: { title: "A" },
                                 using: { fts5: { dictionary: "english", prefix: true } }

    EnglishArticle.create!(title: "Running fast")

    # Prefix + English stemming work together. "fast" is not stemmed,
    # so prefix "fa*" matches "fast" in the index.
    assert_equal 1, EnglishArticle.search("fa").count
  end

  # === Validation ===

  def test_unknown_dictionary_raises_at_searchable_by_time
    err = assert_raises(Knitsearch::UnknownDictionaryError) do
      Article.searchable_by against: { title: "A" },
                            using: { fts5: { dictionary: "klingon" } }
    end
    assert_includes err.message, "Unknown dictionary"
    assert_includes err.message, "klingon"
  end

  def test_symbol_dictionary_rejected_with_helpful_message
    err = assert_raises(ArgumentError) do
      Article.searchable_by against: { title: "A" },
                            using: { fts5: { dictionary: :english } }
    end
    assert_includes err.message, "must be a string"
    assert_includes err.message, "dictionary: \"english\""
  end

  # === ActionText + Dictionary ===

  def test_english_with_action_text_field
    EnglishArticle.searchable_by against: { title: "A", content: "B" },
                                 using: { fts5: { dictionary: "english" } }

    EnglishArticle.create!(
      title: "Running",
      content: ActionText::RichText.new(body: "<p>She runs every morning</p>")
    )

    # Both title and content_plain_text are stemmed by porter tokenizer
    results = EnglishArticle.search("run").to_a
    assert_equal 1, results.count
  end

  # === Backfill with dictionary ===

  def test_backfill_with_english_dictionary
    EnglishArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "english" } }

    # Create records after searchable_by using raw SQL to bypass triggers
    title = EnglishArticle.connection.quote("Running fast")
    body = EnglishArticle.connection.quote("She runs")
    EnglishArticle.connection.execute(
      "INSERT INTO english_articles (title, body, created_at, updated_at) VALUES (#{title}, #{body}, datetime('now'), datetime('now'))"
    )

    # Search finds it after backfill
    EnglishArticle.knitsearch_backfill!
    assert_equal 1, EnglishArticle.search("run").count
  end

  # === Combined with other features ===

  def test_english_with_highlight
    EnglishArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "english" } }

    EnglishArticle.create!(title: "anything", body: "Running fast")

    results = EnglishArticle.search("run", highlight: [:body]).to_a
    assert_equal 1, results.count
    # The highlight should mark the stemmed match
    assert_includes results.first.search_highlight(:body), "<mark>"
  end

  def test_english_with_snippet
    EnglishArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "english" } }

    EnglishArticle.create!(title: "anything", body: "She is running fast")

    results = EnglishArticle.search("run", snippet: { body: 20 }).to_a
    assert_equal 1, results.count
    snippet = results.first.search_snippet(:body)
    assert_includes snippet, "running"
  end

  private

  def reset_english_article_state!
    EnglishArticle.instance_variable_set(:@rich_text_mapping, {})
    EnglishArticle.instance_variable_set(:@associated_mapping, {})
    EnglishArticle.instance_variable_set(:@searchable_columns, nil)
    EnglishArticle.instance_variable_set(:@searchable_options, nil)
    EnglishArticle.instance_variable_set(:@searchable_dictionary, nil)
    EnglishArticle.instance_variable_set(:@knitsearch_callbacks_installed, false)
  end
end
