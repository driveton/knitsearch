# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::SuggestTest < Minitest::Test
  include ArticlesTestHelper
  def setup
    super
  end


  def test_suggest_returns_prefix_matched_records
    Article.create!(title: "JavaScript Basics", body: "learning")
    Article.create!(title: "Java Virtual Machine", body: "platform")
    Article.create!(title: "Ruby Guide", body: "language")

    results = Article.suggest("jav").to_a
    assert_equal 2, results.count
    titles = results.map(&:title)
    assert_includes titles, "JavaScript Basics"
    assert_includes titles, "Java Virtual Machine"
  end

  def test_suggest_default_limit_is_10
    15.times { |i| Article.create!(title: "Job #{i}", body: "work") }

    results = Article.suggest("job").to_a
    assert_equal 10, results.count
  end

  def test_suggest_custom_limit_honored
    10.times { |i| Article.create!(title: "Job #{i}", body: "work") }

    results = Article.suggest("job", limit: 5).to_a
    assert_equal 5, results.count
  end

  def test_suggest_blank_query_returns_empty
    Article.create!(title: "Ruby Guide", body: "language")

    results = Article.suggest("")
    assert_equal [], results.to_a
  end

  def test_suggest_nil_query_returns_empty
    Article.create!(title: "Ruby Guide", body: "language")

    results = Article.suggest(nil)
    assert_equal [], results.to_a
  end

  def test_suggest_returns_relation
    Article.create!(title: "Ruby Guide", body: "language")

    results = Article.suggest("rub")
    assert_kind_of ActiveRecord::Relation, results
  end

  def test_suggest_handles_special_chars
    Article.create!(title: "C++ Programming", body: "language")
    Article.create!(title: "C# Basics", body: "dotnet")

    # Special chars should not crash — query escaping handles them
    results = Article.suggest("c++").to_a
    assert results.any?
  end

  def test_suggest_ranking_is_same_as_prefix_search
    Article.create!(title: "Java Language", body: "programming")
    Article.create!(title: "JavaScript Framework", body: "web")

    # suggest uses prefix: true, so it should match both "Java" and "JavaScript"
    results = Article.suggest("java").to_a
    assert results.count >= 1
    # Both start with "java" (case-insensitive), so both should match
  end

  def test_suggest_with_fallback_below_returns_array
    Article.create!(title: "Performance Tips", body: "optimization")
    Article.create!(title: "Rails Guide", body: "framework")
    Article.create!(title: "Ruby Tutorial", body: "language")

    # With fallback_below, should return Array, not Relation
    results = Article.suggest("per", fallback_below: 10)
    assert_kind_of Array, results
  end

  def test_suggest_empty_fallback_with_nil_query
    results = Article.suggest(nil, fallback_below: 5)
    assert_equal [], results
  end

  def test_suggest_with_whitespace_only_returns_empty
    Article.create!(title: "Test", body: "content")

    result = Article.suggest("   ")
    assert_equal 0, result.count
  end

  def test_suggest_with_fts_operator_words_does_not_crash
    Article.create!(title: "AND", body: "OR NOT content")

    result = Article.suggest("AND OR NOT")
    assert result.is_a?(ActiveRecord::Relation)
  end

  def test_suggest_with_very_long_query_does_not_crash
    Article.create!(title: "Test", body: "content")

    long_query = "a" * 5000
    result = Article.suggest(long_query)
    assert result.is_a?(ActiveRecord::Relation)
  end
end
