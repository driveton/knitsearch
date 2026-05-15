# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::SchemaDriftTest < Minitest::Test
  include ArticlesTestHelper

  def test_missing_column_raises_schema_mismatch_error
    err = assert_raises(Knitsearch::SchemaMismatchError) do
      Article.searchable_by against: { title: "A", phantom_column: "B" }
    end
    assert_includes err.message, "phantom_column"
  end

  def test_error_message_names_fts_table
    err = assert_raises(Knitsearch::SchemaMismatchError) do
      Article.searchable_by against: { title: "A", phantom_column: "B" }
    end
    assert_includes err.message, "articles_fts"
  end

  def test_error_message_suggests_migration_fix
    err = assert_raises(Knitsearch::SchemaMismatchError) do
      Article.searchable_by against: { title: "A", phantom_column: "B" }
    end
    assert_match(/migration|searchable_by declaration/, err.message)
  end

  def test_failed_searchable_by_does_not_corrupt_valid_configuration
    Article.searchable_by against: { title: "A", body: "B" }
    Article.create!(title: "Before Error", body: "valid")

    assert_raises(Knitsearch::SchemaMismatchError) do
      Article.searchable_by against: { title: "A", phantom_column: "B" }
    end

    Article.create!(title: "After Error", body: "still valid")
    results = Article.search("valid").to_a
    assert_equal 2, results.count
  end
end
