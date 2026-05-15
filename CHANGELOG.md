# Changelog

## v0.1

- `multisearchable(against:)` — global multi-model search macro. Declares which columns to index in `knitsearches` FTS5 table. `Knitsearch.multisearch(query, limit:)` returns BM25-ranked polymorphic Document relation. Independent from per-model `searchable_by`; both can coexist on the same model with zero extra sync cost.
- Fix after_save_commit callback silently no-op'ing for has_many associated_against — bundled callback registration and method definition into an ActiveSupport::Concern's `included do` block to fix callback-chain compilation timing.
- `dictionary: "trigram"` exposes FTS5's built-in trigram tokenizer for substring search. Zero new dependencies. Cannot be combined with `prefix:`.
- `search(query, match: :phrase)` requires tokens to appear as a contiguous, ordered phrase via FTS5's native phrase queries. Cannot be combined with `operator: :or`.
- `search(query, fallback_below: N)` — Searchkick-style two-pass fallback. Runs a strict AND search first; if fewer than N results, automatically retries with `operator: :or` and merges. Returns an `Array` instead of a `Relation` when used. No-op when combined with `operator: :or`.
- `Model.suggest(query, limit: 10, fallback_below: nil)` — Autocomplete convenience method. Delegates to `search(..., prefix: true)` with a sensible default limit. BM25-ranked results are chainable `ActiveRecord::Relation`s.
- `searchable_by(associated_against: { assoc: [:column] })` — Index fields from belongs_to, has_many, and has_many :through associations. Parent updates cascade to children (belongs_to) or child/join changes refresh parent (has_many, has_many :through). Target updates refresh all parents with that target (has_many :through only).