# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::TrigramTest < Minitest::Test
  include ArticlesTestHelper

  def setup
    super
    reset_trigram_article_state!
    TrigramArticle.delete_all
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                  using: { fts5: { dictionary: "trigram" } }
  end

  private
    def reset_trigram_article_state!
      TrigramArticle.instance_variable_set(:@rich_text_mapping, {})
      TrigramArticle.instance_variable_set(:@associated_mapping, {})
      TrigramArticle.instance_variable_set(:@searchable_columns, nil)
      TrigramArticle.instance_variable_set(:@searchable_options, nil)
      TrigramArticle.instance_variable_set(:@searchable_dictionary, nil)
      TrigramArticle.instance_variable_set(:@knitsearch_callbacks_installed, false)
    end

  # === Dictionary acceptance ===

  def test_trigram_dictionary_accepted
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "trigram" } }

    assert_equal "trigram", TrigramArticle.searchable_dictionary
  end

  def test_trigram_listed_in_supported_dictionaries
    assert_includes Knitsearch::SUPPORTED_DICTIONARIES, "trigram"
  end

  # === Substring search ===

  def test_substring_match_inside_word
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "trigram" } }
    TrigramArticle.create!(title: "railroading", body: "anything")
    TrigramArticle.create!(title: "guardrails", body: "anything")
    TrigramArticle.create!(title: "unrelated", body: "anything")

    assert_equal 2, TrigramArticle.search("rail").count
  end

  def test_substring_match_finds_mit_inside_smith
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "trigram" } }
    TrigramArticle.create!(title: "Smith", body: "anything")

    assert_equal 1, TrigramArticle.search("mit").count
  end

  def test_substring_match_inside_zucchini
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "trigram" } }
    TrigramArticle.create!(title: "zucchini", body: "recipe")

    assert_equal 1, TrigramArticle.search("zucch").count
    assert_equal 1, TrigramArticle.search("chin").count
  end

  # === Chainability ===

  def test_search_returns_chainable_relation
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "trigram" } }
    TrigramArticle.create!(title: "Smith", body: "active")
    TrigramArticle.create!(title: "Smithson", body: "active")

    relation = TrigramArticle.search("mit")
    assert_kind_of ActiveRecord::Relation, relation
    assert_equal 2, relation.count
    assert relation.exists?
  end

  # === Highlight + snippet ===

  def test_highlight_with_trigram
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "trigram" } }
    TrigramArticle.create!(title: "anything", body: "Smith family records")

    results = TrigramArticle.search("smith", highlight: [:body]).to_a
    assert_equal 1, results.count
    assert_includes results.first.search_highlight(:body).to_s, "<mark>"
  end

  def test_snippet_with_trigram
    TrigramArticle.searchable_by against: { title: "A", body: "B" },
                                 using: { fts5: { dictionary: "trigram" } }
    TrigramArticle.create!(title: "anything", body: "The Smith family lives down the road")

    results = TrigramArticle.search("mit", snippet: { body: 10 }).to_a
    assert_equal 1, results.count
    refute_nil results.first.search_snippet(:body)
  end

  # === Validation: prefix is rejected with trigram ===

  def test_trigram_with_prefix_raises_argument_error
    err = assert_raises(ArgumentError) do
      TrigramArticle.searchable_by against: { title: "A" },
                                   using: { fts5: { dictionary: "trigram", prefix: true } }
    end
    assert_includes err.message, "trigram"
    assert_includes err.message, "prefix"
  end

  def test_trigram_with_explicit_prefix_sizes_raises
    err = assert_raises(ArgumentError) do
      TrigramArticle.searchable_by against: { title: "A" },
                                   using: { fts5: { dictionary: "trigram", prefix: [2, 3] } }
    end
    assert_includes err.message, "trigram"
  end

  # === Migration emits the right tokenizer ===

  def test_migration_dictionary_to_tokenizer_returns_trigram
    helper = Object.new.extend(Knitsearch::Migration)
    assert_equal "trigram", helper.send(:dictionary_to_tokenizer, "trigram")
  end
end
