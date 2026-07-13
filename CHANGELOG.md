# Changelog

All notable changes to SQLiteVecKit are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning: [SemVer](https://semver.org) (see DECISIONS.md #4 for what the
wrapper's version promises relative to the bundled sqlite-vec).

## [0.1.1] - 2026-07-13

### Documentation
- Expanded inline DocC comments across the public API so Xcode Quick Help,
  autocomplete, generated DocC, and Swift Package Index documentation expose
  parameter contracts, return values, common errors, and versioning guidance.
- Documented the release strategy for documentation-only changes: source docs
  are versioned in git immediately, while consumers pinned to a package version
  see updated inline docs after the next patch release.

## [0.1.0] - 2026-07-09

Initial release.

### Added
- `VectorStore` actor (Swift 6 strict concurrency) wrapping vendored
  sqlite-vec v0.1.9: `vec0` virtual table, KNN search with cosine (default)
  or L2 distance, `source` filtering inside the KNN query, transactional
  batch inserts with rollback, schema-mismatch detection on open.
- Row metadata: raw JSON `String?` with `Codable` conveniences
  (`VectorEntry(id:content:source:encoding:vector:)`,
  `SearchResult.decodeMetadata(_:)`) and a per-store byte limit
  (`metadataByteLimit`, default 16 KB).
- Lexical search: companion FTS5 index over `content`, kept in sync on every
  write; `searchText(_:topK:source:where:bindings:)` ranked by BM25 with full
  FTS5 query syntax. Opt out per store with `lexicalSearch: false` at init
  (frozen into the file).
- Hybrid search: `searchHybrid(text:vector:...)` fusing vector and lexical
  results with Reciprocal Rank Fusion (k = 60), returning `HybridSearchResult`.
- SQL filtering: every search accepts a `where:` fragment with `bindings:`
  (post-KNN filter in `search`, plain WHERE in `searchText`).
- Raw SQL access: `query(_:bindings:)`/`execute(_:bindings:)` on the actor
  (`SQLValue` in, `SQLRow` out) for consumer-owned tables in the same
  database file, joins against the vector table, and hand-written SQL.
- `[Double]` convenience overloads (`[Float]` is canonical).
- Row/document maintenance: `fetch(id:)`, `update`, `upsert`, `delete(id:)`,
  `delete(source:)`, `deleteAll`, `contains(id:)`, `count()`,
  `count(source:)`, auto-assigned ids via
  `insert(content:source:metadata:vector:) -> Int`.
- `init(dbURL:...)` convenience; `Codable` value types.
- Supply-chain provenance: checksum-locked vendoring of the sqlite-vec
  amalgamation with a verify/update script, CI drift check, and third-party
  notices.
- CI building and testing on macOS (debug + release, NEON-vs-scalar gate).
- DocC catalog with a Getting Started article.
