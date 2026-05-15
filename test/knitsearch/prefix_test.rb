# frozen_string_literal: true

require_relative "../test_helper"

class Knitsearch::PrefixTest < Minitest::Test
  include ArticlesTestHelper
  # === Query.escape unit tests ===

  def test_query_escape_default_no_prefix
    result = Knitsearch::Query.escape("rails")
    assert_equal '"rails"', result
  end

  def test_query_escape_prefix_false
    result = Knitsearch::Query.escape("rails", prefix: false)
    assert_equal '"rails"', result
  end

  def test_query_escape_prefix_true_single_token
    result = Knitsearch::Query.escape("rails", prefix: true)
    assert_equal '"rails"*', result
  end

  def test_query_escape_prefix_true_multiple_tokens
    result = Knitsearch::Query.escape("ruby rails", prefix: true)
    assert_equal '"ruby"* "rails"*', result
  end

  def test_query_escape_prefix_internal_quotes
    # Test that internal quotes are escaped (doubled) in each token
    result = Knitsearch::Query.escape('say "hello" world', prefix: true)
    assert_equal '"say"* """hello"""* "world"*', result
  end

  def test_query_escape_prefix_with_or_operator
    result = Knitsearch::Query.escape("rails ruby", operator: :or, prefix: true)
    assert_equal '"rails"* OR "ruby"*', result
  end

  def test_query_escape_prefix_with_and_operator
    result = Knitsearch::Query.escape("rails ruby", operator: :and, prefix: true)
    assert_equal '"rails"* "ruby"*', result
  end

  # === Migration DDL tests ===

  def test_migration_prefix_nil_omits_option
    connection = ActiveRecord::Base.connection
    connection.execute("DROP TABLE IF EXISTS test_prefix_table")
    connection.execute(<<~SQL)
      CREATE TABLE test_prefix_table (
        id INTEGER PRIMARY KEY,
        content TEXT
      )
    SQL

    # Manual migration call with prefix: nil (default)
    migration = Class.new(ActiveRecord::Migration[8.1]) do
      include Knitsearch::Migration
    end
    m = migration.new
    m.create_searchable_table "test_prefix_table", columns: ["content"]

    # Check DDL — should NOT have prefix='...'
    ddl = connection.select_one("SELECT sql FROM sqlite_master WHERE name = 'test_prefix_table_fts'")["sql"]
    assert_includes ddl, "content='test_prefix_table'"
    assert_includes ddl, "tokenize="
    refute_includes ddl, "prefix="

    connection.execute("DROP TABLE IF EXISTS test_prefix_table_fts")
    connection.execute("DROP TABLE test_prefix_table")
  end

  def test_migration_prefix_true_emits_2_3
    connection = ActiveRecord::Base.connection
    connection.execute("DROP TABLE IF EXISTS test_prefix_true")
    connection.execute(<<~SQL)
      CREATE TABLE test_prefix_true (
        id INTEGER PRIMARY KEY,
        content TEXT
      )
    SQL

    migration = Class.new(ActiveRecord::Migration[8.1]) do
      include Knitsearch::Migration
    end
    m = migration.new
    m.create_searchable_table "test_prefix_true", columns: ["content"], prefix: true

    ddl = connection.select_one("SELECT sql FROM sqlite_master WHERE name = 'test_prefix_true_fts'")["sql"]
    assert_includes ddl, "prefix='2 3'"

    connection.execute("DROP TABLE IF EXISTS test_prefix_true_fts")
    connection.execute("DROP TABLE test_prefix_true")
  end

  def test_migration_prefix_custom_array
    connection = ActiveRecord::Base.connection
    connection.execute("DROP TABLE IF EXISTS test_prefix_custom")
    connection.execute(<<~SQL)
      CREATE TABLE test_prefix_custom (
        id INTEGER PRIMARY KEY,
        content TEXT
      )
    SQL

    migration = Class.new(ActiveRecord::Migration[8.1]) do
      include Knitsearch::Migration
    end
    m = migration.new
    m.create_searchable_table "test_prefix_custom", columns: ["content"], prefix: [2, 3, 4]

    ddl = connection.select_one("SELECT sql FROM sqlite_master WHERE name = 'test_prefix_custom_fts'")["sql"]
    assert_includes ddl, "prefix='2 3 4'"

    connection.execute("DROP TABLE IF EXISTS test_prefix_custom_fts")
    connection.execute("DROP TABLE test_prefix_custom")
  end

  # === Integration tests ===

  def test_prefix_search_finds_partial_match_when_enabled
    reset_articles!

    # Create article with "Performance Tips" — user searches for "Perform"
    Article.searchable_by against: { title: "A" }, using: { fts5: { prefix: true } }
    Article.create!(title: "Performance Tips", body: "optimization advice")

    results = Article.search("Perform").to_a
    assert_equal 1, results.count
    assert_match(/Performance Tips/, results.first.title)
  end

  def test_prefix_search_no_match_without_prefix
    reset_articles!

    Article.searchable_by against: { title: "A" }
    Article.create!(title: "Performance Tips", body: "optimization advice")

    # Default: no prefix matching
    results = Article.search("Perform").to_a
    assert_equal 0, results.count
  end

  def test_prefix_option_flows_from_searchable_options
    reset_articles!

    Article.searchable_by against: { title: "A" }, using: { fts5: { prefix: true } }
    Article.create!(title: "Ruby Rails Guide", body: "frameworks")

    # Partial match "Rai" should find "Rails"
    results = Article.search("Rai").to_a
    assert_equal 1, results.count
    assert_match(/Ruby Rails Guide/, results.first.title)
  end

  private

  def reset_articles!
    Article.delete_all
    connection = Article.connection
    connection.execute("DELETE FROM sqlite_sequence WHERE name = 'articles'") rescue nil
  end
end
