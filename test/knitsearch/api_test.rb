# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::APITest < Minitest::Test
  include ArticlesTestHelper

  def test_against_with_bucket_weights
    Article.searchable_by against: { title: "A", body: "B" }
    assert_equal({ "title" => 8, "body" => 4 }, Article.searchable_columns)
    assert_equal({}, Article.searchable_options)
  end

  def test_against_with_numeric_weights
    Article.searchable_by against: { title: 5, body: 1 }
    assert_equal({ "title" => 5.0, "body" => 1.0 }, Article.searchable_columns)
    assert_equal({}, Article.searchable_options)
  end

  def test_against_with_using
    Article.searchable_by against: { title: "A" }, using: { fts5: { prefix: true } }
    assert_equal({ "title" => 8 }, Article.searchable_columns)
    assert_equal({ fts5: { prefix: true } }, Article.searchable_options[:using])
  end

  def test_associated_against_with_undefined_association_raises
    assert_raises(Knitsearch::ConfigurationError) do
      Article.searchable_by against: { title: "A" }, associated_against: { author: [:name] }
    end
  end

  def test_all_weight_buckets
    reset_api_test_article_state!
    ApiTestArticle.delete_all
    ApiTestArticle.searchable_by against: { a: "A", b: "B", c: "C", d: "D" }
    assert_equal({ "a" => 8, "b" => 4, "c" => 2, "d" => 1 }, ApiTestArticle.searchable_columns)
  end

  private
    def reset_api_test_article_state!
      ApiTestArticle.instance_variable_set(:@rich_text_mapping, {})
      ApiTestArticle.instance_variable_set(:@associated_mapping, {})
      ApiTestArticle.instance_variable_set(:@searchable_columns, nil)
      ApiTestArticle.instance_variable_set(:@searchable_options, nil)
      ApiTestArticle.instance_variable_set(:@searchable_dictionary, nil)
      ApiTestArticle.instance_variable_set(:@knitsearch_callbacks_installed, false)
    end

  def test_bucket_weights_case_insensitive
    Article.searchable_by against: { title: "a", body: "b" }
    assert_equal({ "title" => 8, "body" => 4 }, Article.searchable_columns)
  end

  def test_requires_against_keyword
    assert_raises(ArgumentError) do
      Article.searchable_by :title, :body
    end
  end

  def test_requires_against_not_positional
    assert_raises(ArgumentError) do
      Article.searchable_by title: 5, body: 1
    end
  end

  def test_a_weighted_ranks_higher_than_b
    reset_articles!

    Article.searchable_by against: { title: "A", body: "B" }

    Article.create!(title: "Database Guide", body: "about systems")
    Article.create!(title: "Performance Tips", body: "database optimization techniques")

    results = Article.search("database", highlight: [:title, :body]).to_a

    assert_equal 2, results.count
    assert_match(/Database Guide/, results.first.title)
    assert_match(/Performance Tips/, results.last.title)
  end

  def test_snippet_with_string_token_count
    reset_articles!
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "word word word word word")

    # String "20" should be coerced to integer without error
    results = Article.search("word", snippet: { body: "20" }).to_a
    assert_equal 1, results.count
  end

  def test_snippet_with_zero_tokens_raises
    reset_articles!
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "word word")

    err = assert_raises(ArgumentError) do
      Article.search("word", snippet: { body: 0 }).to_a
    end
    assert_includes err.message, "snippet token count must be positive"
  end

  def test_search_with_nil_query_returns_none
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "content")

    result = Article.search(nil)
    assert_equal ActiveRecord::Relation.none.class, result.class
    assert_equal 0, result.count
  end

  def test_search_with_empty_string_returns_none
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "content")

    result = Article.search("")
    assert_equal 0, result.count
  end

  def test_search_with_whitespace_only_returns_none
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "content")

    result = Article.search("   ")
    assert_equal 0, result.count
  end

  def test_search_with_fts_operator_words_does_not_crash
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "AND OR NOT content")

    result = Article.search("AND OR NOT")
    assert result.is_a?(ActiveRecord::Relation)
  end

  def test_search_with_very_long_query_does_not_crash
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "content")

    long_query = "a" * 5000
    result = Article.search(long_query)
    assert result.is_a?(ActiveRecord::Relation)
  end

  def test_snippet_with_negative_tokens_raises
    reset_articles!
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "word word")

    err = assert_raises(ArgumentError) do
      Article.search("word", snippet: { body: -5 }).to_a
    end
    assert_includes err.message, "snippet token count must be positive"
  end

  def test_snippet_with_non_numeric_tokens_raises
    reset_articles!
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Test", body: "word word")

    assert_raises(ArgumentError) do
      Article.search("word", snippet: { body: "abc" }).to_a
    end
  end

  def test_searchable_by_is_idempotent
    reset_articles!

    # First call
    Article.searchable_by against: { title: "A", body: "B" }
    callbacks_first = Article._save_callbacks.count

    # Second call
    Article.searchable_by against: { title: "A", body: "B" }
    callbacks_second = Article._save_callbacks.count

    # No additional callbacks should be registered
    assert_equal callbacks_first, callbacks_second,
                 "Calling searchable_by twice should not register callbacks twice"
  end

  private

  def reset_articles!
    Article.delete_all
    connection = Article.connection
    connection.execute("DELETE FROM sqlite_sequence WHERE name = 'articles'") rescue nil
  end
end
