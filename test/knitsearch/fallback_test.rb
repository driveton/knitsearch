# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::FallbackTest < Minitest::Test
  include ArticlesTestHelper
  def setup
    super
    @ruby_rails = Article.create!(title: "Ruby on Rails", body: "framework")
    @rails_only = Article.create!(title: "Rails is great", body: "framework")
    @ruby_only = Article.create!(title: "Ruby language", body: "language")
  end


  def test_no_fallback_when_strict_meets_threshold
    results = Article.search("ruby rails", fallback_below: 1)
    assert_equal 1, results.size
    assert_equal @ruby_rails, results.first
  end

  def test_fallback_widens_and_to_or_when_strict_is_sparse
    results = Article.search("ruby rails", fallback_below: 5)
    ids = results.map(&:id)
    assert_includes ids, @ruby_rails.id
    assert_includes ids, @rails_only.id
    assert_includes ids, @ruby_only.id
  end

  def test_strict_matches_rank_above_fallback_matches
    results = Article.search("ruby rails", fallback_below: 5)
    assert_equal @ruby_rails, results.first
  end

  def test_fallback_dedupes_records_appearing_in_both_passes
    results = Article.search("ruby rails", fallback_below: 5)
    ids = results.map(&:id)
    assert_equal ids.uniq, ids
  end

  def test_returns_array_when_fallback_below_passed
    results = Article.search("ruby rails", fallback_below: 5)
    assert_kind_of Array, results
    refute_kind_of ActiveRecord::Relation, results
  end

  def test_returns_array_even_when_fallback_does_not_trigger
    # Strict pass meets threshold of 1 — still returns Array per Option A
    results = Article.search("ruby rails", fallback_below: 1)
    assert_kind_of Array, results
  end

  def test_limit_caps_merged_total
    results = Article.search("ruby rails", fallback_below: 10, limit: 2)
    assert_equal 2, results.size
  end

  def test_strict_pass_returning_zero_falls_back_entirely_to_lenient
    results = Article.search("ruby zzznonsense", fallback_below: 5)
    refute_empty results
    ids = results.map(&:id)
    assert_includes ids, @ruby_rails.id
    assert_includes ids, @ruby_only.id
  end

  def test_fallback_below_with_or_is_a_noop
    results = Article.search("ruby rails", fallback_below: 5, operator: :or)
    assert_kind_of ActiveRecord::Relation, results
  end

  def test_fallback_below_nil_behaves_like_default
    results = Article.search("ruby rails", fallback_below: nil)
    assert_kind_of ActiveRecord::Relation, results
    assert_equal 1, results.count
  end

  def test_fallback_below_zero_behaves_like_default
    results = Article.search("ruby rails", fallback_below: 0)
    assert_kind_of ActiveRecord::Relation, results
  end

  def test_fallback_with_phrase_falls_back_to_word_in_lenient_pass
    # Strict phrase "ruby rails" matches nothing (not contiguous in any row).
    # Fallback widens to word + :or and should find ruby-only and rails-only rows.
    results = Article.search("ruby rails", fallback_below: 5, match: :phrase)
    refute_empty results
    ids = results.map(&:id)
    assert_includes ids, @ruby_only.id
    assert_includes ids, @rails_only.id
  end

  def test_fallback_works_with_highlight
    results = Article.search("ruby rails", fallback_below: 5, highlight: [:title])
    assert(results.any? { |r| r.search_highlight(:title).to_s.include?("<mark>") })
  end

  def test_fallback_with_empty_query_returns_empty_array
    results = Article.search("", fallback_below: 5)
    assert_equal [], results
  end

  def test_fallback_with_nil_query_returns_empty_array
    results = Article.search(nil, fallback_below: 5)
    assert_equal [], results
  end
end
