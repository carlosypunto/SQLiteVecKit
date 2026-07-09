# AGENTS.md

Guidance for AI coding agents (opencode, Codex, Cursor, Claude Code) working in this repository. Canonical, tool-agnostic.

## Overview

`SQLiteVecKit` is a Swift Package that wraps [sqlite-vec](https://github.com/asg017/sqlite-vec) v0.1.9 and exposes a single Swift API — `VectorStore` — for on-device vector search in iOS/macOS apps. No external Swift dependencies. Architecture decisions with their rationale live in `DECISIONS.md` (repo root).

## Build & test

```bash
# From this directory
swift build              # also compiles Snippets/ — the doc examples
swift build -c release   # release matters: it exercises the optimized NEON codegen

swift test                                          # full suite (both test targets)
swift test -c release                               # NEON-vs-scalar consistency gate
swift test --filter CSQLiteVecTests                 # C-layer tests only
swift test --filter SQLiteVecStoreTests.InsertTests # a single suite
swift test --filter singleInsertSucceeds            # a single test by name

# Documentation gate (CI runs this; broken symbol links fail it):
xcodebuild docbuild -scheme SQLiteVecKit -destination 'generic/platform=macOS' \
    OTHER_DOCC_FLAGS='--warnings-as-errors'
```

Docs notes: the fenced code blocks in `Sources/SQLiteVecStore/SQLiteVecStore.docc/*.md` (and the README blocks marked with a `<!-- Mirrors Snippets/… -->` comment) **mirror the files in `Snippets/`** (kept in sync by hand — `@Snippet` directives don't resolve under `xcodebuild docbuild`, only under the swift-docc-plugin, which this package deliberately doesn't depend on). When the API changes: fix the snippet (compiler enforces), then update its mirrored block (the comment above each block names the snippet file). Overloaded symbols in the `.docc` landing page Topics need DocC disambiguation hashes — get the real ones from a docbuild archive (`data/documentation/sqlitevecstore/vectorstore/*.json` filenames), never invent them. `docs.yml` validates docs on every push/PR and deploys them to GitHub Pages on push to main.

Tests use the Swift Testing framework (`import Testing`, `@Suite`/`@Test`, not XCTest). Swift-wrapper tests open a fresh SQLite file under `FileManager.default.temporaryDirectory` and remove it in a `defer`; C-layer tests use `:memory:` databases.

## Package structure

| Target | Language | Role |
|---|---|---|
| `CSQLiteVec` | C (clang) | sqlite-vec amalgamation (compiled via `SQLiteVecShim.c`) + thin bootstrap wrapper. Not exported to consumers. |
| `SQLiteVecStore` | Swift | Public API (`VectorStore`, `VectorEntry`, `SearchResult`, `DistanceMetric`, `SQLiteError`). The only product. |
| `SQLiteVecStoreTests` | Swift | Swift Testing suite covering the whole `VectorStore` API (init, schema mismatch, CRUD, batch, search, filtered search, errors). Also depends on `CSQLiteVec` to build schema-mismatch fixtures. |

Inside `SQLiteVecStore` the source is split by role: value types live under `Sources/SQLiteVecStore/Types/` (one file per type), the actor under `Sources/SQLiteVecStore/Store/` — `VectorStore.swift` holds state/init/schema validation, the public API is split across `VectorStore+Insert/+Search/+Mutations/+RawSQL.swift` extensions, and shared plumbing sits in `VectorStore+Helpers.swift`. The actor's stored properties and helpers are `internal` (not `private`) because Swift's `private` is file-scoped and the extension files need them. Test suites are likewise grouped by area into one file per area plus `TestSupport.swift` (shared `tmpPath`/`withStore` helpers).
| `CSQLiteVecTests` | Swift | Drives the raw sqlite3 C API against the bundled amalgamation: bootstrap, versions, vec0 DDL/KNN semantics, NEON-vs-scalar distance consistency. |

## Key design decisions

- **`sqlite-vec.c` and `sqlite-vec.h` are the unmodified upstream amalgamation.** Do not edit them. The header lives at `Sources/CSQLiteVec/sqlite-vec.h` (deliberately *not* in `include/`, so it is private to the target); only `SQLiteVecBootstrap.h` is public.
- **`SQLiteVecShim.c` is the only compilation entry for the amalgamation.** It defines `SQLITE_VEC_ENABLE_NEON` on arm64 and then `#include`s `sqlite-vec.c`. The upstream NEON gate is NOT arch-guarded internally (it unconditionally includes `<arm_neon.h>`), and SPM `cSettings` cannot be per-architecture — hence the shim. `Package.swift` lists the shim in `sources:` and excludes `sqlite-vec.c`.
- **`SQLiteVecBootstrap.c/h`** exposes `sqlite_vec_bootstrap(sqlite3*)` (calls `sqlite3_vec_init`) and `sqlite_vec_bundled_version()`. Registration is per-connection — `sqlite3_auto_extension` is deprecated on Apple platforms (upstream #132). The header's `#include <sqlite3.h>` is what re-exports the system sqlite3 API to Swift; it must stay.
- **System `sqlite3`** is linked via `linkerSettings: [.linkedLibrary("sqlite3")]`. No bundled SQLite.
- **Embeddings are passed as binary blobs** (`[Float]` bytes via `sqlite3_bind_blob`), not as JSON text.
- **KNN queries use `WHERE embedding MATCH ? AND k = ?`**, never `LIMIT ?` — LIMIT only works as a KNN constraint on SQLite ≥ 3.41 and breaks with JOINs (upstream #116/#96). `topK` is capped at `VectorStore.maxTopK` (4096, sqlite-vec's `vec_max_k`).
- **`source` is a vec0 metadata column; `content` and `metadata` are auxiliary (`+`) columns.** Metadata columns are filterable in KNN WHERE but inefficient for strings > 12 chars; aux columns are cheap for long text but cannot be filtered on (DECISIONS.md #2).
- **`metadata` is a raw `String?` (usually JSON), size-capped at write time** against the per-store `metadataByteLimit` (default `VectorStore.defaultMetadataByteLimit`, 16 KB) — throws `.metadataTooLarge`. Codable conveniences: `VectorEntry(id:content:source:encoding:vector:)` (distinct `encoding:` label so a plain `String` never gets JSON-double-encoded) and `SearchResult.decodeMetadata(_:)`, both backed by the internal `MetadataJSON` enum (`.sortedKeys`, compact).
- **`[Float]` is canonical; `[Double]` overloads are `@_disfavoredOverload`.** `VectorEntry.init`, `insert`, `search`, and `searchHybrid` accept `[Double]` and convert via `map(Float.init)`. The disfavored attribute keeps numeric-literal arrays (`[1, 0, 0]`) resolving to `[Float]` instead of being ambiguous (DECISIONS.md #3).
- **Lexical search is a manually synced FTS5 companion table** (`<table>_fts`, rowid == vec0 id). Triggers are forbidden on virtual tables, so every write path mirrors into it inside the same transaction (`withTransaction` is nesting-aware via `sqlite3_get_autocommit`). Governed by the `lexicalSearch:` init flag (default true), frozen into the file: flag/file disagreement or a DB with only one of the two tables → `.schemaMismatch`; text/hybrid search on a disabled store → `.lexicalSearchDisabled` (DECISIONS.md #5). Never write to the FTS table directly.
- **Hybrid search = Reciprocal Rank Fusion (k = 60)** over both overfetched lists (`min(topK*4, maxTopK)`); ties break by id for determinism. BM25 and vector distances are never numerically compared.
- **Filtering is raw SQL** (`where:` fragment + `bindings: [SQLValue]` on every search — there is intentionally no typed filter DSL; see DECISIONS.md #6). In `search` the fragment wraps the KNN as a **`MATERIALIZED` CTE post-filter — MATERIALIZED is load-bearing**: without it SQLite's WHERE push-down moves the fragment into the KNN query and vec0 rejects aux-column constraints. In `searchText` it is a plain WHERE (only `content` needs `c.` qualification there).
- **`query(_:bindings:)`/`execute(_:bindings:)`** expose the actor's connection (sqlite-vec loaded) for consumer tables in the same DB — the only sane route, since a second connection can't load vec0 (`CSQLiteVec` is not exported). Conventions (not compiler-enforced): vec0 table is a read contract (writes via typed API only — raw writes bypass FTS sync), `_fts` is internal, no manual BEGIN/COMMIT. The vec0 column layout is therefore public API: reshaping it is a major-version event.
- **Wrapper semver is independent of sqlite-vec's pre-1.0 status** (DECISIONS.md #4): an upstream change that breaks the Swift API or invalidates DB files forces a wrapper major bump.
- **Schema mismatch is detected at init.** `CREATE VIRTUAL TABLE IF NOT EXISTS` would silently keep an existing table with a different schema, so `setUpSchema` compares normalized DDL from `sqlite_master` against the machine-generated DDL and throws `.schemaMismatch`. No migration — re-embedding cannot be done by the store.
- **`upsert` is DELETE + INSERT in one transaction** because `INSERT OR REPLACE` is broken on vec0 tables (upstream #259). `update` checks existence via `contains(id:)` rather than `sqlite3_changes()`, whose virtual-table reporting is not guaranteed.
- **`VectorStore` is `actor`** — Swift 6 concurrency-safe. All public methods must be called with `await`. Swift 6 actors do not enqueue work on their executor during `init`, so actor-isolated instance methods cannot be called from it — this is why `setUpSchema` is an internal `static` method taking the raw `OpaquePointer` directly, bypassing actor isolation.
- **`DBHandle`** is an internal `final class` (`@unchecked Sendable`) that owns the `OpaquePointer` and calls `sqlite3_close` in `deinit` — the actor deinit isolation workaround (a Swift 6 actor's `deinit` is `nonisolated` and cannot safely access actor-isolated properties; ARC releasing `DBHandle` when the actor deallocates triggers the close instead).
- **Only `FLOAT[N]` embeddings are supported; there is no public vector-type enum.** `INT8[N]`/`BIT[N]` support is deferred until sqlite-vec v1.0 confirms stable syntax and blob formats (DECISIONS.md #1). `init` takes `dimension: Int` directly.

## Vendoring & supply-chain provenance

- **`Sources/CSQLiteVec/checksums.lock`** SHA-256-locks `sqlite-vec.c`/`sqlite-vec.h` against the pinned upstream release (`v0.1.9`). `scripts/vendor-sqlite-vec.sh verify` checks the lock (and confirms `LICENSE-MIT`/`LICENSE-APACHE` are present — existence-only, not hash-locked, since license text is a redistribution obligation rather than versioned bytes); `... update` re-vendors from a bumped `UPSTREAM_REF` and rewrites the lock.
- **No `vendor/` subdirectory.** `sqlite-vec.c`/`.h`, `checksums.lock`, and the license files all sit directly under `Sources/CSQLiteVec/`, not in a nested `vendor/` folder — keeps `Package.swift`'s `path`/`headerSearchPath` and the shim's relative `#include`s unchanged.
- **The amalgamation is fetched from the GitHub Release asset tarball, never the raw source tree.** Upstream only commits a `sqlite-vec.h.tmpl` template at the repo root — the real generated `sqlite-vec.h` ships only inside `sqlite-vec-X.Y.Z-amalgamation.tar.gz`. `LICENSE-MIT`/`LICENSE-APACHE`, by contrast, are plain committed files and are fetched via `raw.githubusercontent.com`.
- **`Sources/CSQLiteVec/LICENSE-MIT` and `LICENSE-APACHE`** are vendored standalone (verbatim upstream text) since sqlite-vec is dual-licensed MIT OR Apache-2.0. The root `LICENSE` points at them instead of inlining either.
- **`THIRD-PARTY-NOTICES.md`** (repo root) is the canonical, detailed third-party attribution doc (upstream URL, pinned version, vendored paths, "Modifications: none"). The root `NOTICE` is a short pointer to it — the two are deliberately not duplicated to avoid drift.
- **CI (`.github/workflows/vendor-check.yml`) and an opt-in local `pre-push` hook (`.githooks/pre-push`, enable via `git config core.hooksPath .githooks`)** both run `scripts/vendor-sqlite-vec.sh verify` and fail on any drift between the vendored bytes and the lock.

## Upgrading sqlite-vec

1. Bump `UPSTREAM_REF` in `scripts/vendor-sqlite-vec.sh`, run `scripts/vendor-sqlite-vec.sh update` (re-vendors `sqlite-vec.c`/`sqlite-vec.h` + both license files, rewrites `checksums.lock`), then `scripts/vendor-sqlite-vec.sh verify` to confirm before committing.
2. Verify in the new `sqlite-vec.c` that the SIMD gate is still named `SQLITE_VEC_ENABLE_NEON` (the shim depends on it) and still lacks an internal `__ARM_NEON` guard.
3. Verify `SQLITE_VEC_VERSION` in the new `sqlite-vec.h`, then update the version string in: `THIRD-PARTY-NOTICES.md` ("Vendored version"), `README.md` (Third-Party Attribution), this file's Overview, `CSQLiteVecTests`' `bundledVersionMatchesHeader` expectation, `SQLiteVecStoreTests`' `bundledVecVersionIsExposed` expectation.
4. Build/test gate: `swift build`, `swift build -c release`, `swift test`, `swift test -c release`. The `CSQLiteVecTests` suites (vec0 DDL/KNN semantics, SIMD consistency) are the upgrade regression gate.
5. **Pre-v1.0 risk:** sqlite-vec makes no stability guarantees before v1.0 — `vec0` syntax and column type declarations may change between minor releases. Re-verify `insertBatch`/`search` in `Store/VectorStore+Insert.swift` and `Store/VectorStore+Search.swift` after any bump.
6. **v0.1.10-alpha (ANN indexes: DiskANN/IVF/rescore) intentionally not adopted** — evaluate once a stable v0.1.10 ships.

## Watching for sqlite-vec v1.0

sqlite-vec is pre-v1.0; the upstream README warns of breaking changes. Monitor <https://github.com/asg017/sqlite-vec/releases>. When v1.0 lands, audit for: `vec0` syntax changes (column declarations, `MATCH` operator, `knn_params`, distance function defaults); binary blob format confirmation for `float32`; `INT8[N]`/`BIT[N]` stability (once confirmed, consider a public vector-configuration API per DECISIONS.md #1); header or symbol renames (`sqlite3_vec_init` etc). Patch bumps at v1.0.x should be safe to apply immediately; minor bumps (v1.x.0) warrant a review of the above.

## `VectorStore` public API

```swift
public enum DistanceMetric: String, Sendable { case l2, cosine }
public enum SQLValue: Sendable { case int(Int), double(Double), text(String), blob(Data), null }
public struct SQLRow: Sendable {                    // query() row: subscript -> SQLValue?, typed accessors
    func int/double/text/blob(_ column: String) -> T?   // double() also coerces .int
    var columnNames: [String]
}

public struct VectorEntry: Sendable, Equatable, Codable {
    let id: Int; let content: String; let source: String; let metadata: String?; let vector: [Float]
    init(id:content:source:metadata: String? = nil, vector: [Float])
    init(id:content:source:encoding: some Encodable, vector: [Float]) throws   // JSON-encodes metadata
    // + @_disfavoredOverload [Double] variants of both
}
public struct SearchResult: Sendable, Equatable, Identifiable, Codable {
    let id: Int; let content: String; let source: String; let metadata: String?; let distance: Double
    func decodeMetadata<M: Decodable>(_ type: M.Type) throws -> M?             // nil if no metadata
}
public struct HybridSearchResult: Sendable, Equatable, Identifiable, Codable {
    let id: Int; let content: String; let source: String; let metadata: String?
    let score: Double                               // RRF, HIGHER = better
    let vectorRank: Int?; let textRank: Int?        // 1-based; nil if absent from that list
}

init(dbPath: String,                                // also init(dbURL: URL, ...)
     dimension: Int = 512,                          // >= 1, else .invalidDimension
     distanceMetric: DistanceMetric = .cosine,
     tableName: String = "chunks",                  // restricted to [A-Za-z_][A-Za-z0-9_]*
     metadataByteLimit: Int = VectorStore.defaultMetadataByteLimit,
     lexicalSearch: Bool = true) throws             // frozen into the file

static var bundledVecVersion: String                // "v0.1.9"
static let maxTopK = 4096
static let defaultMetadataByteLimit = 16_384

func insert(_ entry: VectorEntry) throws
func insert(id: Int, content: String, source: String, metadata: String? = nil, vector: [Float]) throws  // + [Double]
func insert(content: String, source: String, metadata: String? = nil, vector: [Float]) throws -> Int    // auto id; + [Double]
func insertBatch(_ entries: [VectorEntry]) throws   // single transaction; pre-validated; ROLLBACK on error
func search(vector: [Float], topK: Int = 5, source: String? = nil,
            where: String? = nil, bindings: [SQLValue] = []) throws -> [SearchResult]                   // + [Double]
func searchText(_ query: String, topK: Int = 5, source: String? = nil,
                where: String? = nil, bindings: [SQLValue] = []) throws -> [SearchResult]  // BM25 in .distance; .invalidTextQuery / .lexicalSearchDisabled
func searchHybrid(text: String, vector: [Float], topK: Int = 5, source: String? = nil,
                  where: String? = nil, bindings: [SQLValue] = []) throws -> [HybridSearchResult]       // + [Double]
func query(_ sql: String, bindings: [SQLValue] = []) throws -> [SQLRow]     // raw SQL (conventions apply)
func execute(_ sql: String, bindings: [SQLValue] = []) throws -> Int        // rows changed
func fetch(id: Int) throws -> VectorEntry?          // full row incl. embedding
func update(_ entry: VectorEntry) throws            // .rowNotFound if id missing; replaces the whole row
func upsert(_ entry: VectorEntry) throws
func delete(id: Int) throws                         // no-op if missing
func delete(source: String) throws                  // per-document re-ingest unit
func deleteAll() throws
func contains(id: Int) throws -> Bool
func count() throws -> Int
func count(source: String) throws -> Int
```

The schema (machine-generated by `createTableSQL`/`createFTSTableSQL`):
```sql
CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING vec0(
    id INTEGER PRIMARY KEY,
    embedding FLOAT[N] distance_metric=cosine,  -- N = dimension
    source TEXT,
    +content TEXT,
    +metadata TEXT
);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(content);  -- rowid == chunks.id
```

## Not-yet-implemented roadmap

- **`INT8[N]`/`BIT[N]` support** is not present in the 0.1.0 API. It is deferred pending sqlite-vec v1.0 API stability: add a per-type column declaration, implement `insertCore`/`search` bindings for `INT8[N]` (`[Int8]` raw blob) and `BIT[N]` (`Data`, 1 bit/dimension packed), and consider a typed value model or overloads to enforce the correct element type at the call site.
- **Database migration** (changing the vector configuration of an existing store) is deferred until `INT8`/`binary` support lands — it requires recreating the virtual table and re-embedding all content from source, which the store cannot do alone (it only retains embeddings, not raw text). Sketch: `func migrate(to newConfiguration:, using embedder: some EmbeddingProvider) async throws`.
- **Switching to an official sqlite-vec SPM package**, if/when upstream publishes one (`sqlite-dist.toml` already declares `spm = {}`): remove `Sources/CSQLiteVec/sqlite-vec.c`/`.h` and the `CSQLiteVec` target, add the upstream package as a dependency, adjust `SQLiteVecBootstrap.c/.h` and the `Sources/SQLiteVecStore/Store/` imports accordingly. Benefit: version resolution via SPM, no manual vendoring. Risk: the official package's API surface may differ from the raw amalgamation.

## Design rationale

**Everything under `Sources/CSQLiteVec/` except the bootstrap and shim is extracted from the upstream repo <https://github.com/asg017/sqlite-vec>.** That repo's issues and PRs can be useful background when working in this directory — but only the ones relevant to the *Swift wrapper* (i.e. how the `VectorStore` actor in `Sources/SQLiteVecStore/Store/` binds to and calls the C API: `sqlite3_vec_init`, the `vec0` virtual table SQL syntax, column type declarations, blob formats for `FLOAT[N]`/`INT8[N]`/`BIT[N]`). Issues/PRs about the internals of the amalgamation itself (query planner, C implementation details, other language bindings) are out of scope — `sqlite-vec.c`/`sqlite-vec.h` are unmodified upstream files and are not meant to be patched here (see "Upgrading sqlite-vec" above instead).
