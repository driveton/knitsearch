# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::PhraseTest < Minitest::Test
  include ArticlesTestHelper
  def setup
    super
    Article.searchable_by against: { title: "A", body: "B" }

    @on_rails = Article.create!(title: "ruby on rails", body: "framework")
    @rails_ruby = Article.create!(title: "rails ruby", body: "languages")
    @just_ruby = Article.create!(title: "just ruby", body: "language")
    @just_rails = Article.create!(title: "rails only", body: "framework")
  end


  def test_phrase_mode_matches_contiguous_sequence
    results = Article.search("ruby on rails", match: :phrase).to_a
    assert_includes results, @on_rails
    refute_includes results, @rails_ruby
    refute_includes results, @just_ruby
    refute_includes results, @just_rails
  end

  def test_default_word_mode_is_unchanged
    results = Article.search("ruby rails").to_a
    assert_includes results, @on_rails
    assert_includes results, @rails_ruby
    refute_includes results, @just_ruby
    refute_includes results, @just_rails
  end

  def test_phrase_mode_with_or_raises
    err = assert_raises(ArgumentError) do
      Article.search("ruby on rails", match: :phrase, operator: :or).to_a
    end
    assert_match(/phrase cannot be combined with operator: :or/, err.message)
  end

  def test_single_token_phrase_equals_single_token_word
    phrase_results = Article.search("rails", match: :phrase).order(:id).to_a
    word_results   = Article.search("rails").order(:id).to_a
    assert_equal word_results, phrase_results
  end

  def test_phrase_mode_strips_control_characters
    results = Article.search("ruby\x00on\x01rails", match: :phrase).to_a
    assert_includes results, @on_rails
  end

  def test_phrase_mode_escapes_internal_quotes
    Article.create!(title: %(He said hello there loudly), body: "x")
    # Should not raise even with quotes in the input
    results = Article.search(%(hello "there"), match: :phrase).to_a
    assert_kind_of Array, results
  end

  def test_phrase_mode_returns_chainable_relation
    relation = Article.search("ruby on rails", match: :phrase)
    assert_kind_of ActiveRecord::Relation, relation
    assert_respond_to relation, :where
    assert_respond_to relation, :includes
    assert_respond_to relation, :count
    assert_respond_to relation, :exists?
  end

  def test_phrase_mode_with_empty_query_returns_none
    assert_equal [], Article.search("", match: :phrase).to_a
    assert_equal [], Article.search("   ", match: :phrase).to_a
  end

  def test_phrase_mode_rejects_invalid_match_values
    err = assert_raises(ArgumentError) do
      Article.search("rails", match: :sentence)
    end
    assert_match(/match must be :word or :phrase/, err.message)
  end

  def test_phrase_mode_combines_with_limit
    Article.create!(title: "Ruby on Rails again", body: "Another")
    results = Article.search("ruby on rails", match: :phrase, limit: 1).to_a
    assert_equal 1, results.size
  end

  def test_phrase_mode_combines_with_highlight
    results = Article.search("ruby on rails", match: :phrase, highlight: [:title]).to_a
    assert_includes results.first.search_highlight(:title).to_s, "<mark>"
  end

  # === Query.escape unit tests ===

  def test_escape_phrase_joins_tokens_in_single_quoted_string
    assert_equal %("ruby on rails"), Knitsearch::Query.escape("ruby on rails", match: :phrase)
  end

  def test_escape_phrase_single_token
    assert_equal %("rails"), Knitsearch::Query.escape("rails", match: :phrase)
  end

  def test_escape_phrase_doubles_internal_quotes
    assert_equal %("hello ""there"""), Knitsearch::Query.escape(%(hello "there"), match: :phrase)
  end

  def test_escape_phrase_nil_returns_nil
    assert_nil Knitsearch::Query.escape(nil, match: :phrase)
    assert_nil Knitsearch::Query.escape("", match: :phrase)
  end

  def test_escape_word_default_unchanged
    assert_equal %("ruby" "on" "rails"), Knitsearch::Query.escape("ruby on rails")
  end
end
