# SQLiteVecKit

![CI](https://github.com/carlosypunto/SQLiteVecKit/actions/workflows/ci.yml/badge.svg)
![Vendor check](https://github.com/carlosypunto/SQLiteVecKit/actions/workflows/vendor-check.yml/badge.svg)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%2B%20%7C%20macOS%2014%2B-blue)
![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen)

A lightweight Swift Package that bundles [sqlite-vec](https://github.com/asg017/sqlite-vec) and exposes a single Swift API for on-device **vector, lexical (BM25), and hybrid search** in iOS and macOS apps.

No network, no external services. Vectors are stored in a SQLite database using sqlite-vec's `vec0` virtual table, with a companion FTS5 index for full-text search. On arm64 (all iOS devices and Apple Silicon Macs) distance computations use sqlite-vec's NEON SIMD fast paths.

Design decisions (why only `FLOAT[N]` embeddings are exposed, how metadata is stored, why `[Float]` is the canonical vector type) are recorded in [DECISIONS.md](DECISIONS.md).

## Platform Requirements

| Platform | Minimum Version |
|----------|----------------|
| iOS      | 17.0           |
| macOS    | 14.0           |

Swift tools version: 6.0 (Xcode 16.0+)

## Installation

### In Xcode

1. Open your project in Xcode.
2. **File > Add Package Dependencies…**
3. Enter the repository URL: `https://github.com/carlosypunto/SQLiteVecKit`
4. Select the version rule (e.g. **Up to Next Major** from `0.1.0`).
5. Add `SQLiteVecStore` to your app target under **Frameworks and Libraries**.

### In Package.swift

```swift
let package = Package(
    // ...
    dependencies: [
        .package(url: "https://github.com/carlosypunto/SQLiteVecKit", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "YourTarget",
            dependencies: [
                .product(name: "SQLiteVecStore", package: "SQLiteVecKit")
            ]
        )
    ]
)
```

## How to use

`VectorStore` is a Swift `actor`: it is safe to share across tasks, and all its methods must be called with `await` from an async context.

The typical RAG-style flow is:

1. [Create a store](#1-create-a-store) whose `dimension` matches your embedding model.
2. [Define a metadata type](#2-optional-define-a-metadata-type) (optional) for per-chunk extra data.
3. [Insert your chunks](#3-insert-your-chunks) — one `VectorEntry` per chunk, ideally with `insertBatch`.
4. [Search](#4-search) with a query embedding and read back content, source, and metadata.
5. [Keep the store up to date](#5-update-upsert-delete-read-back) with `update`/`upsert`/`delete`/`fetch`.
6. Optionally add [lexical & hybrid search](#6-lexical--hybrid-search), [SQL filtering](#7-filtering-with-sql), [your own tables](#8-your-own-tables-in-the-same-database), and an [embedding-space manifest](#9-embedding-space-manifest).

### 1. Create a store

```swift
import Foundation
import SQLiteVecStore

let url = URL.documentsDirectory.appendingPathComponent("vectors.db")
let store = try VectorStore(
    dbPath: url.path,
    dimension: 512,            // MUST match your embedding model's output size
    distanceMetric: .cosine,   // default; use .l2 for Euclidean distance
    tableName: "chunks"        // default; [A-Za-z_][A-Za-z0-9_]* only
    // metadataByteLimit: VectorStore.defaultMetadataByteLimit  (16 KB)
    // lexicalSearch: true     // maintain the FTS5 index for searchText/searchHybrid
)
```

The initializer opens (or creates) the SQLite file, registers the sqlite-vec extension on that connection, and creates the virtual table if it does not already exist.

**`dimension` is not a free choice** — it must equal the length of the vectors your embedding model produces. Every insert and search validates vector length against it and throws `SQLiteError.dimensionMismatch` on disagreement. Common models:

| Model | Dimension |
|---|---|
| `all-MiniLM-L6-v2` (sentence-transformers) | 384 |
| Apple `NLEmbedding` (sentence, English) | 512 |
| OpenAI `text-embedding-3-small` | 1536 |
| OpenAI `text-embedding-3-large` | 3072 |
| Cohere `embed-v4` (default) | 1536 |

**`distanceMetric`** — `.cosine` (default) is what most text-embedding models are trained for; distances fall in `[0, 2]`. `.l2` is Euclidean distance, `[0, ∞)`. In both, **lower means more similar**.

> **Important:** `dimension`, `distanceMetric`, and the column layout are fixed when the database file is first created. Opening an existing file with a different configuration throws `SQLiteError.schemaMismatch` — the store never silently reuses a table with a different schema. There is no automatic migration: recreate the file and re-ingest (re-embedding cannot be done by the store, which only holds the embeddings).

### 2. (Optional) Define a metadata type

Each row can carry a free-form metadata string — typically JSON — alongside `content` and `source`. Define a `Codable` type and let the package handle the JSON:

```swift
struct ChunkInfo: Codable {
    let page: Int
    let section: String
    let ingestedAt: Date
}
```

Metadata is capped at `metadataByteLimit` UTF-8 bytes per row (default 16 KB, configurable in the initializer). Oversized metadata throws `SQLiteError.metadataTooLarge` before anything is written. It is stored in a vec0 *auxiliary* column: cheap for long text, but **not filterable** in searches — only `source` can filter a KNN query.

### 3. Insert your chunks

One `VectorEntry` per chunk:

```swift
// With Codable metadata (note the `encoding:` label — the value is JSON-encoded for you):
let entry = try VectorEntry(
    id: 42,                                   // unique per row; you own id assignment
    content: "The mitochondria is the powerhouse of the cell.",
    source: "biology_notes.txt",              // filterable in searches
    encoding: ChunkInfo(page: 3, section: "Cells", ingestedAt: .now),
    vector: embedding                         // [Float] (or [Double]), exactly `dimension` elements
)

// With a raw pre-built JSON string (stored verbatim), or no metadata at all:
let raw   = VectorEntry(id: 43, content: "…", source: "…", metadata: #"{"page":4}"#, vector: v)
let plain = VectorEntry(id: 44, content: "…", source: "…", vector: v)

try await store.insert(entry)

// Labeled convenience, without building a VectorEntry:
try await store.insert(id: 45, content: "…", source: "…", vector: v)

// Or let SQLite assign the id (returned):
let newID = try await store.insert(content: "…", source: "…", vector: v)
```

For ingestion, always prefer **`insertBatch`** — it wraps all inserts in a single SQLite transaction, which is dramatically faster than row-by-row inserts, and it is all-or-nothing: entries are pre-validated (dimension and metadata size) before any write, and any mid-batch failure (e.g. a duplicate id) rolls the whole batch back:

```swift
let entries: [VectorEntry] = documents.flatMap { doc in
    chunk(doc).enumerated().map { index, text in
        VectorEntry(id: doc.baseID + index, content: text, source: doc.name,
                    vector: embed(text))
    }
}
try await store.insertBatch(entries)
```

Inserting an id that already exists throws (`id` is the primary key). If you want replace-on-collision semantics, use [`upsert`](#5-update-upsert-delete).

### 4. Search

Embed the query with the **same model** you used for ingestion, then:

```swift
let results = try await store.search(vector: queryEmbedding, topK: 5)

for result in results {
    print("[\(result.id)] [\(result.source)] d=\(result.distance)")
    print(result.content)
    if let info = try result.decodeMetadata(ChunkInfo.self) {
        print("page \(info.page), section \(info.section)")
    }
}
```

`search` returns `[SearchResult]` ordered by ascending distance (best match first). Each result carries `id`, `content`, `source`, `metadata` (the raw string, `nil` if none), and `distance`. `topK` must be in `1...VectorStore.maxTopK` (4096, sqlite-vec's `vec_max_k` limit); fewer rows are returned if the store is smaller.

To restrict the search to one source (applied *inside* the KNN query, via a vec0 metadata column — so `topK` counts only matching rows):

```swift
let results = try await store.search(vector: queryEmbedding, topK: 5, source: "biology_notes.txt")
```

### 5. Update, upsert, delete, read back

```swift
try await store.update(entry)         // throws .rowNotFound if the id does not exist
try await store.upsert(entry)         // insert-or-replace (transactional DELETE + INSERT)
try await store.delete(id: 42)        // no-op if the id does not exist
try await store.delete(source: "doc") // drop every chunk of one document (re-ingest unit)
try await store.deleteAll()
let entry  = try await store.fetch(id: 42)        // full row incl. embedding, nil if missing
let exists = try await store.contains(id: 42)
let total  = try await store.count()
let inDoc  = try await store.count(source: "doc")
```

`update` and `upsert` replace the **whole row** (content, source, metadata, and embedding) — an entry with `metadata: nil` clears any stored metadata. `upsert` is implemented as DELETE + INSERT in one transaction because `INSERT OR REPLACE` is broken on `vec0` tables ([upstream issue #259](https://github.com/asg017/sqlite-vec/issues/259)).

`delete(source:)` + `insertBatch` is the natural way to re-ingest a changed document without tracking chunk ids.

For app-level stale-state tracking, keep your own `indexed_documents` table with the document id/path, content hash, chunk count, manifest version, and last indexed date. Document content changes are per-document re-ingests; embedding-space changes (model, dimension, metric, pooling, transform) require a new database or a full delete/reingest.

### 6. Lexical & hybrid search

Vector search misses exact terms (names, codes, acronyms); the store also maintains an FTS5 full-text index over `content`, updated automatically on every write:

```swift
// Lexical, ranked by BM25 (SearchResult.distance carries the BM25 score;
// negative, lower = better). FTS5 syntax: terms, "phrases", AND/OR/NOT, prefix*.
let lexical = try await store.searchText("mitochondria", topK: 5)

// Hybrid: vector + lexical fused with Reciprocal Rank Fusion — a row that
// scores well in both lists ranks first. `score` is higher = better.
let hybrid = try await store.searchHybrid(text: question, vector: queryEmbedding, topK: 5)
for hit in hybrid {
    print(hit.content, hit.score, hit.vectorRank ?? "-", hit.textRank ?? "-")
}
```

A malformed FTS5 query (e.g. an unbalanced quote) throws `SQLiteError.invalidTextQuery`. Both methods accept the same `source:`, `where:`, and `bindings:` parameters as `search`.

The FTS index is created by default; if you don't need lexical search, opt out at creation time with `lexicalSearch: false` in the initializer (frozen into the file like the rest of the configuration — `searchText`/`searchHybrid` then throw `SQLiteError.lexicalSearchDisabled`).

### 7. Filtering with SQL

Every search accepts an optional SQL fragment. Write values as `?` placeholders and pass them in `bindings:` — never interpolate values into the fragment:

<!-- Mirrors Snippets/FilteringWithSQL.swift (compile-checked by `swift build`). -->
```swift
let results = try await store.search(
    vector: queryEmbedding,
    topK: 20,
    where: "json_extract(metadata, '$.lang') = ? AND json_extract(metadata, '$.page') > ?",
    bindings: [.text("en"), .int(10)]
)
```

The fragment sees the columns `id`, `content`, `source`, `metadata`, and `distance` (in `searchText`, qualify `content` as `c.content` — the bare name is ambiguous with the FTS join). Anything SQLite can evaluate works: `json_extract` for metadata, `LIKE`, `IN`, subqueries against your own tables…

> **Post-filter semantics in `search`:** vec0 cannot filter auxiliary columns inside the KNN query, so KNN selects `topK` rows first and the fragment runs afterwards — you may get fewer than `topK` results. Raise `topK` when filtering. In `searchText` the fragment is an ordinary WHERE condition with no such caveat. Rows without metadata never match `json_extract` predicates.

Prefer `source:` for document/source filters. Use `where:` for post-filters, joins, JSON metadata, and reporting-style predicates. If recall matters, overfetch and trim:

<!-- Mirrors Snippets/FilteringWithSQL.swift (compile-checked by `swift build`). -->
```swift
let candidates = try await store.search(
    vector: queryEmbedding,
    topK: 50,
    where: "json_extract(metadata, '$.section') = ?",
    bindings: [.text("Cells")]
)
let visible = Array(candidates.prefix(5))
```

`searchHybrid` forwards the same fragment to both the vector and FTS paths, so keep it valid in both contexts. Bare `id`, `source`, `metadata`, and `distance` are the safest shared columns; reserve `c.content` qualification for text-only searches.

### 8. Your own tables in the same database

The store's connection — with sqlite-vec already loaded — is available for raw SQL, so your app's tables can live in the same file and join against the vector table:

```swift
try await store.execute("CREATE TABLE IF NOT EXISTS docs(name TEXT PRIMARY KEY, author TEXT)")
try await store.execute("INSERT INTO docs VALUES (?, ?)", bindings: [.text("bio"), .text("Alice")])

let rows = try await store.query("""
    SELECT c.content, d.author
    FROM chunks c JOIN docs d ON d.name = c.source
    WHERE c.id = ?
    """, bindings: [.int(1)])
let author = rows.first?.text("author")   // typed accessors: int/double/text/blob
```

**Conventions** (enforced by documentation, not by the compiler — see DECISIONS.md #6):

- The store's vec0 table (`chunks` by default) is a **read** contract: query it freely, but write to it only through the typed API — raw SQL writes bypass validation and the FTS sync.
- The `<table>_fts` index is **internal**: never read from or write to it directly.
- Don't manage transactions (`BEGIN`/`COMMIT`) via `execute` around store methods; the store handles its own.

### 9. Embedding-space manifest

`VectorStore` validates the SQLite schema, but your app owns the embedding pipeline. Store a manifest in your own table and compare it before querying:

<!-- Mirrors Snippets/EmbeddingSpaceManifest.swift (compile-checked by `swift build`). -->
```swift
struct EmbeddingSpaceManifest: Codable, Equatable {
    let modelID: String
    let modelRevision: String
    let dimension: Int
    let distanceMetric: String
    let languageStrategy: String
    let poolingStrategy: String
    let transformID: String?
    let transformVersion: String?
    let centroidHash: String?
}
```

Fields that invalidate the index include model id/revision, dimension, distance metric, language strategy, pooling strategy, transform id/version, and any centroid/hash for corpus-derived transforms. Changing one means old and new vectors are not comparable: create a new database or delete and re-ingest from source content. SQLiteVecKit deliberately does not own that manifest because it does not own chunking, embedding, pooling, or transforms.

### Cancellation

The API is async because `VectorStore` is an actor, but SQLite execution is synchronous once a call is running on that actor: cancellation is observed between operations, never mid-statement. The full semantics and rationale live in the *Searching & Filtering* guide of the DocC catalog (see [Documentation](#documentation)).

### Working with `[Double]` embeddings

Some embedding APIs hand back `[Double]` (JSON decoding defaults floating-point numbers to `Double`). The canonical vector type is `[Float]` — sqlite-vec stores 32-bit floats, so `Double` precision cannot be persisted anyway — but every entry point has a `[Double]` overload that converts for you:

```swift
let doubles: [Double] = try await fetchEmbedding(for: query)

let entry   = VectorEntry(id: 1, content: "…", source: "…", vector: doubles)
try await store.insert(id: 2, content: "…", source: "…", vector: doubles)
let results = try await store.search(vector: doubles, topK: 5)
```

The conversion is `map(Float.init)`; the precision lost is irrelevant for embedding similarity.

### Error handling

All methods throw `SQLiteError` (`LocalizedError`):

```swift
do {
    try await store.insert(entry)
} catch let error as SQLiteError {
    print(error.localizedDescription)  // includes SQLite error code and detail message
}
```

Cases you may want to handle specifically: `.schemaMismatch` (existing file created with a different configuration), `.dimensionMismatch` (wrong vector length), `.metadataTooLarge` (metadata over the store's byte limit), `.rowNotFound` (from `update`), `.invalidTextQuery` (malformed FTS5 syntax), `.lexicalSearchDisabled` (text/hybrid search on a `lexicalSearch: false` store), `.invalidTopK`, `.invalidDimension`, and `.invalidTableName`.

### Diagnostics

```swift
VectorStore.bundledVecVersion  // "v0.1.9"
```

## What this package does not do

SQLiteVecKit is storage and retrieval, not a full ingestion or RAG pipeline. It does not provide chunking, embedding generation, pooling, mean-centering or other transforms, manifest ownership, reranking, prompt assembly, or domain recall rules. Keep those in the consuming app so they can evolve without changing the on-disk vector store contract.

## Virtual table schema

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING vec0(
    id INTEGER PRIMARY KEY,
    embedding FLOAT[N] distance_metric=cosine,  -- N = dimension; metric from init
    source TEXT,                                -- metadata column: filterable in KNN queries
    +content TEXT,                              -- auxiliary column: cheap storage for long text
    +metadata TEXT                              -- auxiliary column: optional JSON, size-limited
);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(content);  -- lexical index; rowid == id
```

`source` is a vec0 *metadata column* so it can be used as a filter inside KNN queries. `content` and `metadata` are *auxiliary columns* (`+` prefix): efficient for long text, but they cannot appear in a KNN `WHERE` clause. The FTS5 companion table is maintained automatically by the store — never write to it directly.

## FAQ / Troubleshooting

**`schemaMismatch` when opening an existing file** — the file was created with a different `dimension`, `distanceMetric`, or table layout. There is no automatic migration (the store holds embeddings, not the source text needed to re-embed): delete the file and re-ingest.

**`dimensionMismatch` on insert or search** — the vector's length differs from the store's `dimension`. Check that ingestion and querying use the same embedding model, and that `dimension` matches its output size.

**Why `[Float]` and not `[Double]`?** — sqlite-vec stores `FLOAT[N]` (float32), so double precision cannot be persisted. `[Double]` overloads exist and convert for you; see [DECISIONS.md](DECISIONS.md) #3.

**Is FTS5 always available?** — yes on Apple's system SQLite for the supported OS versions; the test suite includes capability tests (`C.SystemCapabilities`) that fail loudly if an OS ever ships without FTS5, `bm25()`, or JSON1.

**Fewer results than `topK` when using `where:`** — expected: in `search` the fragment runs *after* the KNN selection. Raise `topK`.

## Local benchmarks

An opt-in benchmark test is available for local measurements. It is skipped by default:

```bash
swift test
SQLITEVECKIT_RUN_BENCHMARKS=1 swift test --filter VectorStoreBenchmark
```

The benchmark prints hardware, build configuration, row counts, and timings for batch insert, vector search, lexical search, and hybrid search over deterministic synthetic data. Search timings are the median of 5 runs after a warmup; batch insert is a single run. Treat the numbers as local guidance, not a CI gate.

## Documentation

The API is documented with DocC: Quick Help (⌥-click) and autocomplete show inline comments for the public API, and **Product > Build Documentation** in Xcode renders the full catalog — a Getting Started article plus guides on embedding-space manifests, searching & filtering, the schema lifecycle, and raw SQL conventions.

The code examples in the docs are mirrored by compilable snippets under `Snippets/`, so `swift build` guarantees they stay in sync with the API. CI validates the docs themselves (broken symbol links and DocC warnings fail the build) and publishes the current `main` documentation to GitHub Pages on every push. Hosted docs are also available via the [Swift Package Index](https://swiftpackageindex.com) once the package is listed there (`.spi.yml` is in place).

Documentation is versioned in two layers:

- Source comments, DocC articles, README, and snippets are ordinary repository files, so every commit records the documentation state.
- Consumers pinned to a SwiftPM version see the inline docs and DocC catalog from that tag. Documentation-only improvements should normally ship as a patch release (for example `0.1.1`), while GitHub Pages can continue showing the latest `main` docs between releases.

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Versioning

Releases follow [SemVer](https://semver.org); see [CHANGELOG.md](CHANGELOG.md) for the release history. The version number covers the wrapper's Swift API and the on-disk layout it generates — independent of the bundled sqlite-vec's own pre-1.0 status (policy in [DECISIONS.md](DECISIONS.md) #4). Documentation-only releases use patch versions because they do not change the public API contract or database layout.

## Third-Party Attribution

This package bundles **sqlite-vec** v0.1.9 — a vector search extension for SQLite — as an unmodified C amalgamation (`sqlite-vec.c`, `sqlite-vec.h`).

- Author: Alex Garcia ([@asg017](https://github.com/asg017))
- Repository: <https://github.com/asg017/sqlite-vec>
- License: **MIT OR Apache-2.0** (dual license, at the user's option)

The amalgamation has not been modified. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the full attribution, and [LICENSE](LICENSE) for how this project's own MIT license relates to it.

### Verifying the vendored source

`Sources/CSQLiteVec/sqlite-vec.c` and `sqlite-vec.h` are pinned to a specific upstream release and checksum-locked in `Sources/CSQLiteVec/checksums.lock` (SHA-256). `scripts/vendor-sqlite-vec.sh verify` re-checks the vendored bytes against that lock file and confirms `Sources/CSQLiteVec/LICENSE-MIT` / `LICENSE-APACHE` are present. It runs in CI on every push and PR ([.github/workflows/vendor-check.yml](.github/workflows/vendor-check.yml)) and can optionally run as a local `pre-push` git hook (see [.githooks/pre-push](.githooks/pre-push) — opt in with `git config core.hooksPath .githooks`; this is not enabled automatically).

## License

SQLiteVecKit (the Swift wrapper) is released under the **MIT License**.  
See [LICENSE](LICENSE) for details. Third-party license texts — including sqlite-vec's MIT and Apache-2.0 options — are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), `Sources/CSQLiteVec/LICENSE-MIT`, and `Sources/CSQLiteVec/LICENSE-APACHE`.
