# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tempfile"

require "active_support"
require "active_support/core_ext/module/attribute_accessors"
require "active_record"
require "action_dispatch"
require "rails/engine"

# Use a file-based SQLite database for consistent behavior across tests
# Delete it once at startup to ensure a clean initial state
TEST_DB_BASE = File.expand_path("../tmp/test", __dir__)
TEST_DB = "#{TEST_DB_BASE}.sqlite3"
Dir.mkdir(File.dirname(TEST_DB)) unless Dir.exist?(File.dirname(TEST_DB))
# Delete the database and any WAL files to ensure clean state
%w[.sqlite3 .sqlite3-wal .sqlite3-shm].each do |ext|
  file = "#{TEST_DB_BASE}#{ext}"
  File.delete(file) if File.exist?(file)
end

ActiveRecord::Base.configurations = {
  "test" => {
    "primary" => { "adapter" => "sqlite3", "database" => TEST_DB }
  }
}

ActiveRecord::Base.establish_connection(:test)

# Configure SQLite for consistent FTS5 behavior
conn = ActiveRecord::Base.connection
conn.execute("PRAGMA journal_mode = DELETE")

# Set up ActionText stubs before requiring the gem
require_relative "support/action_text_stubs"

# Create the articles table
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS articles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title VARCHAR(255),
    body TEXT,
    published BOOLEAN DEFAULT 0,
    content_plain_text TEXT,
    content_body TEXT,
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

require "knitsearch"

# Hook multisearchable onto ActiveRecord::Base
ActiveRecord::Base.include Knitsearch::Multisearchable

class Article < ActiveRecord::Base
  include Knitsearch::Model
  has_rich_text :content
end

# Fixture models for different FTS dictionaries (with their own source tables)
class TrigramArticle < ActiveRecord::Base
  self.table_name = "trigram_articles"
  include Knitsearch::Model
  has_rich_text :content
end

class EnglishArticle < ActiveRecord::Base
  self.table_name = "english_articles"
  include Knitsearch::Model
  has_rich_text :content
end

class ApiTestArticle < ActiveRecord::Base
  self.table_name = "api_test_articles"
  include Knitsearch::Model
  has_rich_text :content
end

# Create source tables for fixture models
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS trigram_articles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title VARCHAR(255),
    body TEXT,
    published BOOLEAN DEFAULT 0,
    content_plain_text TEXT,
    content_body TEXT,
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS english_articles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title VARCHAR(255),
    body TEXT,
    published BOOLEAN DEFAULT 0,
    content_plain_text TEXT,
    content_body TEXT,
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS api_test_articles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    a VARCHAR(255),
    b TEXT,
    c TEXT,
    d TEXT,
    published BOOLEAN DEFAULT 0,
    content_plain_text TEXT,
    content_body TEXT,
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

# Create the agendas table
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS agendas (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(255),
    cards_name_plain_text TEXT,
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

# Create the cards table
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS cards (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(255),
    body TEXT,
    agenda_id INTEGER,
    agenda_name_plain_text TEXT,
    tags_name_plain_text TEXT,
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

class Agenda < ActiveRecord::Base
  has_many :cards, dependent: :destroy
  include Knitsearch::Model
end

class Card < ActiveRecord::Base
  belongs_to :agenda
  has_many :card_tags, dependent: :destroy
  has_many :tags, through: :card_tags
  include Knitsearch::Model
end

# Create the card_tags table (join table for Card <-> Tag through :card_tags)
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS card_tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    card_id INTEGER,
    tag_id INTEGER,
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

# Create the tags table
ActiveRecord::Base.connection.execute(<<~SQL)
  CREATE TABLE IF NOT EXISTS tags (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name VARCHAR(255),
    created_at DATETIME,
    updated_at DATETIME
  )
SQL

class CardTag < ActiveRecord::Base
  belongs_to :card
  belongs_to :tag
end

class Tag < ActiveRecord::Base
  has_many :card_tags, dependent: :destroy
  has_many :cards, through: :card_tags
end

# Create FTS tables once at process startup (never recreate per-test)
# These superset schemas cover all test needs; individual tests declare searchable_by
# with subsets if needed.

# articles_fts with simple dictionary (covers most article tests)
Knitsearch::Migration.create_searchable_table(
  "articles",
  columns: { title: "A", body: "B", content_plain_text: "C" },
  dictionary: "simple"
)

# trigram_articles_fts with trigram dictionary
Knitsearch::Migration.create_searchable_table(
  "trigram_articles",
  columns: { title: "A", body: "B", content_plain_text: "C" },
  dictionary: "trigram"
)

# english_articles_fts with english dictionary
Knitsearch::Migration.create_searchable_table(
  "english_articles",
  columns: { title: "A", body: "B", content_plain_text: "C" },
  dictionary: "english"
)

# api_test_articles_fts for api_test.rb (different columns)
Knitsearch::Migration.create_searchable_table(
  "api_test_articles",
  columns: { a: "A", b: "B", c: "C", d: "D" },
  dictionary: "simple"
)

# cards_fts with simple dictionary (superset for all card scenarios)
Knitsearch::Migration.create_searchable_table(
  "cards",
  columns: { name: "A", agenda_name_plain_text: "B", tags_name_plain_text: "C" },
  dictionary: "simple"
)

# agendas_fts with simple dictionary (superset for all agenda scenarios)
Knitsearch::Migration.create_searchable_table(
  "agendas",
  columns: { name: "A", cards_name_plain_text: "B" },
  dictionary: "simple"
)

# knitsearches_fts for multisearch tests
Knitsearch::Migration.create_multisearch_table

# Load test helper modules
require_relative "support/articles_test_helper"
require_relative "support/cards_and_agendas_test_helper"
require_relative "support/multisearch_test_helper"
