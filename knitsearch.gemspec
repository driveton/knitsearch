# frozen_string_literal: true

require_relative "lib/knitsearch/version"

Gem::Specification.new do |spec|
  spec.name        = "knitsearch"
  spec.version     = Knitsearch::VERSION
  spec.authors     = [ "knitsearch contributors" ]
  spec.email       = [ "noreply@driveton.com" ]

  spec.summary     = "Full-text search for Rails 8 + SQLite with ActionText, associations, and multi-model search."
  spec.description = "Knitsearch adds FTS5-backed full-text search to ActiveRecord models. " \
                     "Search by rich text, associated records, or multiple models in one query. " \
                     "Index updates synchronously via SQLite triggers, atomic with source writes. " \
                     "BM25-ranked results returned as a chainable Relation. Supports typo tolerance, " \
                     "phrase matching, prefix matching, highlighting, snippets, and more."
  spec.homepage    = "https://github.com/driveton/knitsearch"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.glob([
    "lib/**/*",
    "MIT-LICENSE",
    "README.md",
    "CHANGELOG.md"
  ])
  spec.require_paths = [ "lib" ]

  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "railties",     ">= 8.0"
  spec.add_dependency "sqlite3",      ">= 2.0"

  spec.add_development_dependency "minitest", ">= 5.0"
end
