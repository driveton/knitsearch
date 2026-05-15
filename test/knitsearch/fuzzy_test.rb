# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::FuzzyTest < Minitest::Test
  include ArticlesTestHelper

  def test_single_term_correction_within_threshold_finds_result
    Article.create!(title: "Zucchini bread", body: "tasty")
    results = Article.search("zucini", fuzzy: 2)
    assert_equal 1, results.size
  end

  def test_single_term_outside_threshold_returns_nothing
    Article.create!(title: "Zucchini bread", body: "tasty")
    results = Article.search("xyzabc", fuzzy: 1)
    assert_equal 0, results.size
  end

  def test_fuzzy_zero_behaves_like_omitted_and_returns_relation
    Article.create!(title: "Ruby on Rails", body: "framework")
    results = Article.search("ruby", fuzzy: 0)
    assert_kind_of ActiveRecord::Relation, results
    assert_equal 1, results.size
  end

  def test_fuzzy_nil_behaves_like_omitted
    Article.create!(title: "Ruby on Rails", body: "framework")
    results = Article.search("ruby", fuzzy: nil)
    assert_kind_of ActiveRecord::Relation, results
  end

  def test_multi_term_correctly_spelled_terms_preserved
    Article.create!(title: "Ruby Rails", body: "framework")
    # "ruby" is in vocab; "raisl" should correct to "rails"
    results = Article.search("ruby raisl", fuzzy: 2)
    assert_equal 1, results.size
  end

  def test_short_tokens_skip_correction
    Article.create!(title: "Ruby on Rails", body: "framework")
    # "ab" is < 3 chars; corrector leaves it alone, returns no match
    results = Article.search("ab", fuzzy: 2)
    assert_equal 0, results.size
  end

  def test_no_candidates_within_threshold_keeps_original
    Article.create!(title: "Zucchini bread", body: "tasty")
    # "zucABC" prefix "zuc" matches "zucchini"; distance = 4 > threshold 1
    results = Article.search("zucABC", fuzzy: 1)
    assert_equal 0, results.size
  end

  def test_correction_runs_before_fallback_below
    Article.create!(title: "Zucchini bread", body: "tasty")
    Article.create!(title: "Bread loaf", body: "wheat")
    # "zucini bred" → "zucchini bred". "bred" has no vocab match (prefix "bre"
    # → "bread"; distance(bred, bread) = 2 > threshold 1). With AND + fallback,
    # widens to OR and matches both rows.
    results = Article.search("zucini bred", fuzzy: 1, fallback_below: 5)
    assert_kind_of Array, results
    assert_operator results.size, :>=, 1
  end

  def test_suggest_does_not_correct_last_token
    Article.create!(title: "Michael Jordan", body: "basketball")
    # "micheal" → "michael" (corrected); "jo" stays as prefix
    results = Article.suggest("micheal jo", fuzzy: 2)
    assert_equal 1, results.size
  end

  def test_nil_query_returns_none
    results = Article.search(nil, fuzzy: 1)
    assert_kind_of ActiveRecord::Relation, results
    assert_equal 0, results.size
  end

  def test_empty_query_returns_none
    results = Article.search("", fuzzy: 1)
    assert_kind_of ActiveRecord::Relation, results
    assert_equal 0, results.size
  end

  def test_correction_skipped_when_vocab_table_missing
    Article.create!(title: "Zucchini bread", body: "tasty")

    conn = ActiveRecord::Base.connection
    vocab_table = Article.vocab_table_name
    conn.execute("DROP TABLE IF EXISTS #{conn.quote_table_name(vocab_table)}")

    begin
      # zucini is not in any document; without correction returns empty
      results = Article.search("zucini", fuzzy: 2)
      assert_equal 0, results.size
    ensure
      fts_table = "articles_fts"
      conn.execute("CREATE VIRTUAL TABLE #{conn.quote_table_name(vocab_table)} USING fts5vocab(#{conn.quote(fts_table)}, 'row')")
    end
  end

  def test_real_word_preserved_when_reasonably_common
    Article.create!(title: "Date night", body: "planned")
    Article.create!(title: "Data science", body: "analysis")
    # "date" exists in vocab. With log-scale ratio, it's preserved.
    results = Article.search("date", fuzzy: 1)
    assert_equal 1, results.size
    assert_equal "Date night", results.first.title
  end

  def test_obvious_typo_is_still_corrected
    # "flight" is overwhelmingly more common than the rare typo "fligh"
    100.times { Article.create!(title: "flight maneuver", body: "real word") }
    Article.create!(title: "fligh", body: "user typo")

    results = Article.search("fligh", fuzzy: 1)

    assert_operator results.size, :>, 1,
      "should correct 'fligh' to 'flight' since the typo is >10x less common"
  end

  def test_suggest_correction_returns_nil_when_input_is_already_correct
    Article.create!(title: "zucchini bread", body: "tasty")
    assert_nil Article.suggest_correction("zucchini")
  end

  def test_suggest_correction_returns_string_when_correction_available
    Article.create!(title: "zucchini bread", body: "tasty")
    assert_equal "zucchini", Article.suggest_correction("zuchini")
  end

  def test_suggest_correction_returns_nil_for_blank_input
    assert_nil Article.suggest_correction(nil)
    assert_nil Article.suggest_correction("")
    assert_nil Article.suggest_correction("   ")
  end
end
