# Knitsearch

Full-text search for Rails 8 + SQLite. Your search index updates in the same transaction as your row. No separate process, no eventual consistency, no extra infrastructure.

Most search gems make you choose: use your database's native FTS and lose rich text plus associated records, or add Elasticsearch and manage another moving part. Knitsearch does both in one line.

**Features that come for free:**

- ActionText rich-text fields. HTML stripped, kept in sync automatically.
- Search by associated model fields (find a Card by its Agenda's name, an Agenda by Card names)
- Multi-model search. One query, polymorphic results, ranked across your whole app.
- Typo tolerance, phrase matching, prefix matching, highlighting, snippets
- BM25 relevance ranking with per-column weights
- One line on the model, one migration

**Query like regular ActiveRecord.** The `.search()` method returns an `Relation`, so `.where`, `.includes`, `.pluck` all work without learning a DSL.

## Installation

Add to your Gemfile:

```ruby
gem "knitsearch"
```

Run the install generator with your model and columns:

```sh
bin/rails generate knitsearch:install Article title body
bin/rails db:migrate
```

The generator creates an FTS5 index and three database triggers that keep it in sync on every insert, update, and delete. All updates happen in the same transaction as your row write.

Add one line to the model:

```ruby
class Article < ApplicationRecord
  include Knitsearch::Model
  searchable_by against: { title: "A", body: "B" }
end
```

If the table already has rows, backfill the index once:

```sh
bin/rails knitsearch:backfill[Article]
```

Then search:

```ruby
articles = Article.search("rails sqlite")
articles.each { |a| puts a.title }
```

## When to use Knitsearch

**Good fit:** Rails app, data in SQLite, you want search to commit and roll back with the row. You're indexing rich text, associated records, or both. You don't want to manage a separate search server.

**Reach for something else if:** You need vector or semantic search (use `sqlite-vec` directly or Meilisearch), distributed search across multiple machines (Elasticsearch, OpenSearch), or per-field synonyms as a first-class feature.

## End-to-end example

A blog with articles, authors, and tags. Start by generating the index:

```sh
bin/rails generate knitsearch:install Article title content
bin/rails db:migrate
```

Then edit the migration to add associated fields. Open `db/migrate/[timestamp]_create_articles_search_table.rb` and update the call:

```ruby
class CreateArticlesSearchTable < ActiveRecord::Migration[8.0]
  def change
    reversible do |dir|
      dir.up do
        Knitsearch::Migration.create_searchable_table(
          "articles",
          columns: ["title"],
          rich_text_columns: ["content"],
          associated_against: {
            author: [:name],
            tags: [:name]
          }
        )
      end

      dir.down do
        Knitsearch::Migration.drop_searchable_table("articles")
      end
    end
  end
end
```

Add the model declaration to match:

```ruby
class Article < ApplicationRecord
  has_rich_text :content
  belongs_to :author
  has_many :article_tags
  has_many :tags, through: :article_tags

  include Knitsearch::Model
  searchable_by(
    against: { title: "A", content: "B" },
    associated_against: { author: [:name], tags: [:name] }
  )
end
```

Run migrations and backfill:

```sh
bin/rails db:migrate
bin/rails knitsearch:backfill[Article]
```

Now you can search articles by title, by their rich-text content (HTML stripped automatically), by the author's name, or by tag names. All in one index:

```ruby
# Search by title or content
Article.search("rails framework")

# Also matches by author name or tag
Article.search("john doe")     # articles by author John Doe
Article.search("ruby")         # articles tagged "ruby"

# Typo tolerance
Article.search("framwork", fuzzy: 1)

# Autocomplete: prefix on the last word, typo-correct the rest
Article.search("jhn do", fuzzy: 1, suggest: true)
# => matches "john doe"

# Phrase matching
Article.search("ruby on rails", match: :phrase)

# Highlight matches
results = Article.search("setup")
results.first.search_highlight(:title)
# => <p>Getting <mark>setup</mark> with Rails</p>

# Extract snippets with context
results.first.search_snippet(:content, 30)
# => <p>...To get <mark>setup</mark> quickly, install...</p>
```

Results are ordered by relevance. Chain any ActiveRecord method:

```ruby
Article.search("rails")
  .where(published: true)
  .includes(:author, :tags)
  .limit(10)
```

When you update an article's title, author, or tags, the search index updates instantly in the same transaction. No drift, no background job, no eventual consistency.

## Querying

The `search` method returns an `ActiveRecord::Relation`. Chain it like any other:

```ruby
Article.search("rails").where(published: true).limit(10).offset(20)
```

### Common queries

Eager-load associations:

```ruby
Article.search("rails").includes(:author)
```

Match either term (default is AND):

```ruby
Article.search("ruby rails", operator: :or)
```

Phrase matching:

```ruby
Article.search("ruby on rails", match: :phrase)
```

Limit results:

```ruby
Article.search("rails", limit: 20)
```

**User input is escaped automatically.** FTS5 syntax characters like `AND`, `OR`, `NOT`, `NEAR`, `*`, `"`, and parentheses become literals. Pass user-typed queries straight in.

### Results and relevance

The `search` method returns results ordered by BM25 relevance, so the most relevant row is first:

```ruby
results = Article.search("rails")
results.count
results.exists?
results.pluck(:title)
```

Empty queries return nothing:

```ruby
Article.search("").to_a     # => []
Article.search(nil).to_a    # => []
```

### Boosting: make some fields rank higher

By default, all fields are weighted equally. Boost important ones:

```ruby
searchable_by against: { title: "A", body: "B", tags: "C" }
```

`"A"` ranks 2 times higher than `"B"`, which ranks 2 times higher than `"C"`. The buckets map to BM25 multipliers: A=8, B=4, C=2, D=1.

You can also use numeric weights directly:

```ruby
searchable_by against: { title: 10, body: 1 }
```

### Typo tolerance

There are two typo-handling APIs because they answer different questions.

**`fuzzy:` rewrites the query.** Use when the user is mid-typing — autocomplete, instant search — where rewriting trailing tokens is the point.

```ruby
Article.search("zuchini", fuzzy: 1)       # rewrites to "zucchini" before searching
Article.search("jhon smtih", fuzzy: 1)    # corrects each token independently
```

`fuzzy:` is the maximum Levenshtein edit distance (number of single-character changes). Use 1 for most words; 2 for words 8+ characters. `fuzzy: 0` or `fuzzy: nil` disables correction. The corrector preserves your word when it's already in the index at reasonable frequency — `"date"` stays as `"date"` even when `"data"` is more common. Only obvious outliers (a typo with vastly fewer occurrences than its corrected form) get rewritten.

**`suggest_correction` returns a suggestion.** Use for one-shot user searches where preserving intent matters. Returns the corrected string OR `nil` — `nil` means the user's spelling was fine and no suggestion is worth showing.

```ruby
suggestion = Article.suggest_correction("zuchini")  # => "zucchini"
Article.suggest_correction("zucchini")              # => nil

# In a controller:
@suggestion = Article.suggest_correction(params[:q])
@articles   = Article.search(params[:q])

# In the view:
# <% if @suggestion %>Did you mean <%= link_to @suggestion, ... %>?<% end %>
```

Each whitespace-separated token is corrected independently against the FTS5 vocab table. Tokens shorter than 3 characters are left alone. Combine with `fallback_below:` to also widen sparse results — correction runs first, then the sparse-results fallback.

### Sparse-results fallback

When a strict AND search returns too few hits, widen automatically:

```ruby
Article.search("zucini", fallback_below: 5)
```

If the AND pass returns fewer than 5 results, the gem retries as OR (and prefix, if enabled). Returns an `Array` rather than a `Relation`. The second pass depends on the first pass's count, so chaining `.where` afterward isn't supported. Filter before the call, or filter in Ruby on the result.

### Highlighting and snippets

Wrap matched terms and extract context:

```ruby
results = Article.search("rails", highlight: [:title], snippet: { body: 30 })
results.first.search_highlight(:title)   # safe HTML, hits wrapped in <mark>
results.first.search_snippet(:body)      # 30-token excerpt with hits marked
```

The `highlight:` option takes an array of column names. The `snippet:` option takes an array (defaults to 20 tokens) or a hash specifying tokens per column. Both return safe HTML.

### Relevance scores

When you use `highlight:` or `snippet:`, results expose their BM25 score:

```ruby
results.first.searchable_score   # => 0.342 (lower = more relevant)
```

Useful for ranking results from multiple `search` calls. For example, you can merge per-model searches into a unified list.

## Indexing

Each search index is an FTS5 virtual table in your SQLite database, kept in sync by triggers. There's no async worker, no separate connection pool, no eventual-consistency window. The index updates inside the same transaction as the row.

### Adding more models

Run the generator for each model:

```sh
bin/rails generate knitsearch:install Comment body
bin/rails db:migrate
```

Each model gets its own FTS table and triggers.

### Backfill

Triggers only catch writes that happen after the FTS table exists. For pre-existing rows:

```sh
bin/rails knitsearch:backfill[Article]
```

This is synchronous. Run once during quiet hours. For fresh apps that install the gem from day one, backfill is a no-op.

### Reindex

If the column set changes or the index gets corrupted:

```ruby
Article.reindex!
```

Or from the command line:

```sh
bin/rails knitsearch:reindex[Article]
```

For models with ActionText fields, use `Article.knitsearch_backfill!` instead. It repopulates shadow columns and rebuilds the index atomically.

## Autocomplete

Build prefix-based suggestions:

```ruby
Article.suggest("rai")
```

This is a thin wrapper over `search(..., prefix: true)` with a default limit of 10. Returns a chainable `Relation` ranked by BM25. Empty queries return nothing.

Correct typos in completed words while still prefix-expanding what the user is typing:

```ruby
Article.suggest("micheal jo", fuzzy: 1)
```

All tokens except the last are corrected. The last is prefix-expanded. So `"micheal jo"` becomes `"michael" + "jo*"`. Combine with `fallback_below:` to also widen sparse results.

### Enable prefix matching on every search

By default, prefix matching is off. The query `search("perf")` won't match `"performance"`. Enable it per-model:

```ruby
class Article < ApplicationRecord
  include Knitsearch::Model
  searchable_by against: { title: "A", body: "B" },
                using: { fts5: { prefix: true } }
end

Article.search("perf")   # now matches "performance", "performing"
```

Defaults to 2 and 3 character prefixes. Customize:

```ruby
using: { fts5: { prefix: [2, 3, 4] } }
```

Prefix indexes are roughly 2 times the size of plain indexes. Cannot be combined with `dictionary: "trigram"` because trigram already covers substring matching.

## Associated fields

Index fields from related records. Updates cascade automatically.

### Setup

To enable associated search, edit the generated migration's `create_searchable_table` call to pass `associated_against:`. For example, if you want a Card to be searchable by its Agenda's name and its Tags' names:

```ruby
# db/migrate/[timestamp]_create_cards_search_table.rb
class CreateCardsSearchTable < ActiveRecord::Migration[8.0]
  def change
    reversible do |dir|
      dir.up do
        Knitsearch::Migration.create_searchable_table(
          "cards",
          columns: ["name", "body"],
          associated_against: {
            agenda: [:name],
            tags: [:name]
          }
        )
      end

      dir.down do
        Knitsearch::Migration.drop_searchable_table("cards")
      end
    end
  end
end
```

Then add the matching `associated_against:` to your model:

```ruby
class Card < ApplicationRecord
  belongs_to :agenda
  has_many :tags
  include Knitsearch::Model
  searchable_by(
    against: { name: "A", body: "B" },
    associated_against: { agenda: [:name], tags: [:name] }
  )
end
```

Run `bin/rails db:migrate`, then `bin/rails knitsearch:backfill[Card]` to index existing rows.

### belongs_to

Search a child record by its parent's fields:

```ruby
class Card < ApplicationRecord
  belongs_to :agenda
  include Knitsearch::Model
  searchable_by(
    against: { name: "A", body: "B" },
    associated_against: { agenda: [:name] }
  )
end

Card.search("real estate")   # matches by agenda.name
```

A shadow column on the Card stores the Agenda's name. When the Agenda updates, the Card's index refreshes via `update_all`.

### has_many

Search a parent record by its children's fields:

```ruby
class Agenda < ApplicationRecord
  has_many :cards
  include Knitsearch::Model
  searchable_by(
    against: { name: "A" },
    associated_against: { cards: [:name] }
  )
end

Agenda.search("john smith")   # matches by any child card's name
```

A shadow column on the Agenda stores space-separated, concatenated child values. When a Card is created, updated, destroyed, or reassigned, the Agenda's index refreshes automatically.

### has_many :through

```ruby
class Card < ApplicationRecord
  has_many :card_tags
  has_many :tags, through: :card_tags
  include Knitsearch::Model
  searchable_by(
    against: { name: "A" },
    associated_against: { tags: [:name] }
  )
end
```

Join row changes and target updates both refresh the Card's index.

**Note:** The `collection.delete(item)` method uses direct SQL and skips destroy callbacks. This is a Rails limitation, not specific to this gem. Use `collection.destroy(item)` so the parent's shadow column refreshes.

### Weights for associated fields

Default weight is `"C"`. Override per column:

```ruby
associated_against: { agenda: { name: "B", description: "C" } }
```

Polymorphic associations are not supported yet.

## ActionText

Index rich-text fields automatically. HTML is stripped and plain text is kept in sync:

```ruby
class Article < ApplicationRecord
  include Knitsearch::Model
  has_rich_text :content
  searchable_by against: { title: "A", content: "B" }
end
```

The generator detects `has_rich_text` and does three things:

1. Creates a `content_plain_text` shadow column
2. Configures the FTS index to read from the shadow column
3. Installs a `before_save` callback that extracts plain text (strips HTML, removes `<action-text-attachment>` elements, collapses whitespace, unescapes entities) and syncs the shadow column

Highlight and snippet operate on the plain text:

```ruby
Article.search("setup", highlight: [:content])
```

For pre-existing records with rich text, use the model method. The rake task skips ActionText:

```ruby
Article.knitsearch_backfill!
```

## Multi-model search

Search every searchable model in one query, returning polymorphic results ranked by BM25. Useful for global search UI.

Set up once:

```sh
bin/rails generate knitsearch:multisearch_install
bin/rails db:migrate
```

Declare which models are searchable:

```ruby
class Card < ApplicationRecord
  multisearchable against: [:name, :body]
end

class Agenda < ApplicationRecord
  multisearchable against: [:name]
end
```

Query:

```ruby
results = Knitsearch.multisearch("vip")
results.first.searchable_score
records = results.includes(:searchable).map(&:searchable)
# => [Card, Agenda, Card, ...]  heterogeneous, BM25-ranked
```

Returns a `Relation` of `Knitsearch::Document`. Each document holds `searchable_type`, `searchable_id`, `content`, and `searchable_score`. Chain like any relation:

```ruby
Knitsearch.multisearch("vip", limit: 10)
Knitsearch.multisearch("vip").where("searchable_type = 'Card'")
```

Backfill existing rows:

```ruby
Card.knitsearch_multisearch_backfill!
Agenda.knitsearch_multisearch_backfill!
```

Per-model and multi-model indexes are independent. Declaring both costs two index writes per row, nothing more.

## Dictionaries

Pick how words are tokenized and matched. Set at install time:

```sh
bin/rails generate knitsearch:install Article title body --dictionary=english
```

Or in the model (must match the migration):

```ruby
searchable_by against: { title: "A", body: "B" },
              using: { fts5: { dictionary: "english" } }
```

| Dictionary | Effect | Tokenizer |
|---|---|---|
| `"simple"` (default) | Case-folded, diacritics removed | `unicode61` |
| `"english"` | English stemming (running becomes run) | `porter` |
| `"trigram"` | Substring matching (mit matches Smith) | `trigram` |

### Trigram tradeoffs

Trigram tokenizes into overlapping 3-character substrings, so any substring is searchable. Useful for last names, product codes, anything where substring matching is natural.

Tradeoffs:
- About 3 times the index size, slower writes
- Query must be at least 3 characters
- Spans whitespace ("d ru" finds "red rubber")
- Cannot combine with `prefix:` because trigram already covers substring matching

To change a dictionary, write a new migration that drops and recreates the FTS table, then run `Model.reindex!`.

## Reference

### Errors

- `Thor::Error` when the generator runs on a non-SQLite adapter
- `Knitsearch::SchemaMismatchError` when a model declares `searchable_by` columns the FTS table doesn't have
- `Knitsearch::ColumnError` when `highlight:` or `snippet:` references a column not in `searchable_by`

All errors inherit from `Knitsearch::Error`.

### Troubleshooting

**Generator says the source table doesn't exist.**
Run `bin/rails db:migrate` first. The generator reads the live schema to validate column names.

**`SchemaMismatchError` after editing `searchable_by`.**
The model declares a column the FTS table doesn't have. Run the generator again with the new columns, then migrate.

**Search returns nothing after install.**
If you added the gem to an existing app, run `bin/rails knitsearch:backfill[Model]`. Triggers only catch writes after the FTS table exists.

**Search returns nothing for a rich-text field.**
Use `Model.knitsearch_backfill!` instead of the rake task. The rake task doesn't populate ActionText shadow columns.

**Generator rejects column names.**
FTS5 column names must be lowercase letters, digits, and underscores. Rename the column or add a shadow column.

**Associated search isn't working.**
Make sure the migration's `associated_against:` hash and the model's `associated_against:` hash match exactly. The keys (association names) and values (column arrays) must be identical. See [Setup](#setup) for an example.

### How it works

The FTS5 table is created with `content='articles'` and `content_rowid='id'`, so it stores only the inverted index and not the source rows. Three triggers (after insert, after delete, after update) fire inside the source table's transaction and keep the index in sync. This is the pattern recommended by SQLite's FTS5 documentation.

A `search` call is a single `SELECT` from the source table, joined to the FTS table on `rowid`, filtered by `MATCH`, ordered by `bm25()`, and limited. No intermediate step. That's why `.where`, `.includes`, `.pluck` all work natively.

### Limitations

- **Trigger overhead on writes.** Every write to a searchable model fires a trigger that updates the FTS table in the same transaction. Negligible for most apps and measurable for high-write workloads. Async indexing is on the roadmap.
- **SQLite only.** The install generator rejects other adapters. Use `pg_search` for PostgreSQL or your database's native FTS.
- **Rails 8.0+, Ruby 3.2+.**
- **Polymorphic associations not supported** by `associated_against:`.

### Roadmap

- Per-language stemming (Spanish, French, etc.) as optional gem dependencies
- Double Metaphone phonetic matching
- Optional async indexing for write-heavy apps
- Vector and semantic search integration (sqlite-vec) for hybrid lexical and embedding ranking

## License

Knitsearch is released under the MIT License.
