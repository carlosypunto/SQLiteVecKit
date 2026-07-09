# Design Decisions

Architecture decision record for SQLiteVecKit. Each entry states the context,
the decision, and the condition under which it should be revisited.

---

## 1. Only `FLOAT[N]` embeddings are exposed in 0.1.0

### Context

sqlite-vec exposes `FLOAT[N]`, `INT8[N]`, and `BIT[N]` column declarations, but
SQLiteVecKit 0.1.0 intentionally supports only `FLOAT[N]` embeddings. sqlite-vec
is **pre-v1.0 and makes no stability guarantees**: the `vec0` column type
declarations, the binary blob formats expected by `sqlite3_bind_blob` for
`INT8[N]` (raw `[Int8]` bytes) and `BIT[N]` (1 bit per dimension, packed), and
the interaction with `distance_metric` (which does not apply to those types)
could all change before v1.0. Shipping Swift bindings against an unstable wire
format would create silent data-corruption risk on upgrade.

The 0.1.0 API should expose only behavior the package can implement and preserve.
That rules out public placeholder cases for vector formats the wrapper cannot
write, read, and search safely yet.

### Decision

- Do not expose a public vector-type enum in 0.1.0.
- `VectorStore.init` takes `dimension: Int = 512` and the embedding column is
  always `FLOAT[N]`.
- Invalid dimensions throw `SQLiteError.invalidDimension` (dimension must be
  >= 1).

### Revisit when

sqlite-vec **v1.0** ships and confirms `INT8[N]`/`BIT[N]` syntax and blob formats
(see "Watching for sqlite-vec v1.0" in `AGENTS.md`). Any future multi-type
support should:

1. Introduce an explicit public vector-configuration API (or separate store
   types) with a per-case SQL column type (`FLOAT[N]` / `INT8[N]` / `BIT[N]`).
2. Keep `distance_metric` limited to `FLOAT[N]` unless sqlite-vec documents
   otherwise.
3. Bind `[Int8]` raw bytes for `INT8[N]` and packed `Data` (1 bit/dimension)
   for `BIT[N]`; prefer a typed value model so the element type is enforced at
   the call site.
4. Keep existing `FLOAT[N]` databases opening unchanged (schema DDL comparison
   in `setUpSchema` is byte-normalized, so the float32 DDL must not change
   shape).

---

## 2. Metadata is a vec0 auxiliary column storing a size-limited JSON string

### Context

Rows needed a free-form metadata field (page numbers, tags, timestamps…) beyond
`content`/`source`. Two vec0 column kinds were possible:

- **Metadata column** (like `source`): filterable inside KNN `WHERE`, but upstream
  documents it as inefficient for strings longer than 12 characters — and a JSON
  blob cannot be usefully filtered with plain comparisons anyway.
- **Auxiliary column** (`+`, like `content`): cheap storage for long text, not
  filterable in KNN queries.

There was also concern about unbounded growth if callers dump arbitrary JSON.

### Decision

- `+metadata TEXT` auxiliary column, nullable. Not filterable by design; `source`
  remains the only KNN filter.
- Public representation is a raw `String?` (`VectorEntry.metadata`,
  `SearchResult.metadata`). Codable conveniences sit on top:
  `VectorEntry(id:content:source:encoding:vector:)` encodes any `Encodable` to
  compact JSON (`.sortedKeys`, deterministic), and
  `SearchResult.decodeMetadata(_:)` decodes it back.
  The Codable initializer uses the distinct `encoding:` label so a plain `String`
  can never accidentally resolve to it and get double-encoded (quoted).
- Size is bounded **by design, not convention**: writes validate
  `metadata.utf8.count <= metadataByteLimit` and throw
  `SQLiteError.metadataTooLarge`. The limit is per-store
  (`init(metadataByteLimit:)`), defaulting to
  `VectorStore.defaultMetadataByteLimit` (16 KB) — generous for chunk metadata,
  small enough to catch "someone serialized the whole document" mistakes.

### Revisit when

- Filtering on structured metadata is needed → promote specific scalar fields to
  real vec0 metadata columns (schema change), not the JSON blob.
- sqlite-vec v1.0 changes aux-column semantics.

---

## 3. `[Float]` is the canonical vector type; `[Double]` accepted as convenience

### Context

sqlite-vec's `FLOAT[N]` stores 32-bit floats; the wrapper binds `[Float]` memory
directly as the blob. Many embedding APIs, however, return `[Double]` (e.g. JSON
decoders default floating numbers to `Double`).

### Decision

- The stored/returned type remains `[Float]` (`VectorEntry.vector`). No `Double`
  storage exists — converting is inherent to the format, not a wrapper choice.
- `[Double]` overloads (`VectorEntry.init`, `VectorStore.insert`,
  `VectorStore.search`) convert with `map(Float.init)`. Precision loss beyond
  float32 is irrelevant for embedding similarity.
- The `[Double]` overloads are `@_disfavoredOverload` so numeric-literal arrays
  (`[1, 0, 0]`) keep resolving to the `[Float]` canonical overload instead of
  becoming ambiguous.

### Revisit when

sqlite-vec adds a `FLOAT64`/double column type and a real `[Double]` storage path
is worth exposing.

---

## 4. Wrapper semver is independent of sqlite-vec's pre-1.0 status

### Context

sqlite-vec (the vendored C extension) is pre-v1.0 and makes no stability
promises. That raised the question of whether SQLiteVecKit can honestly tag a
1.0 while its engine is not stable.

### Decision

- SQLiteVecKit's version number covers **the wrapper's public Swift API and
  the on-disk layout the wrapper generates** — not the bundled sqlite-vec
  version.
- Consequences:
  - Post-1.0, no minor/patch release may change the Swift API incompatibly or
    invalidate existing database files (`.schemaMismatch` on files created by
    the previous release is a major-version event).
  - If an upstream sqlite-vec bump forces either of those (blob format change,
    `vec0` DDL change), the wrapper takes a **major** bump, regardless of how
    small the upstream change looks.
  - Upstream bumps that preserve both are ordinary minor/patch releases.
- 1.0 is tagged only after the 0.1.0 API has soaked in a real consuming app.

### Revisit when

sqlite-vec reaches v1.0 — its own stability guarantees then become part of what
the wrapper can promise (see #1 for the possible future `INT8`/`BIT` expansion).

---

## 5. Lexical search via a manually synced FTS5 companion table

### Context

Vector-only retrieval misses exact-term matches (names, error codes,
acronyms). SQLite ships FTS5 in Apple's system library (guaranteed by a
C-layer capability test), so lexical + hybrid retrieval needs no new
dependencies. But `vec0` is a virtual table, and SQLite forbids triggers on
virtual tables — the classic trigger-based FTS sync is unavailable.

### Decision

- A companion `<table>_fts USING fts5(content)` is created next to the vec0
  table when `lexicalSearch:` is `true` (the default). The flag is frozen into
  the file like the rest of the configuration — reopening with the opposite
  value throws `.schemaMismatch`, and text/hybrid search on a disabled store
  throws `.lexicalSearchDisabled`.
- Its `rowid` equals the vec0 `id`. Every write path in the `VectorStore`
  actor mirrors the change into the FTS table inside the same transaction
  (`withTransaction` is nesting-aware via `sqlite3_get_autocommit`).
- A database whose vec0 table exists without its FTS companion (or vice versa)
  is rejected with `.schemaMismatch` rather than silently indexed-from-now-on.
- Hybrid ranking uses Reciprocal Rank Fusion (k = 60) over the two overfetched
  result lists — no score normalization needed between BM25 and vector
  distances, which are not comparable.

### Revisit when

sqlite-vec v1.0 lands (see #1) or upstream ships built-in hybrid/FTS
integration.

---

## 6. Raw SQL access for filtering and consumer tables; schema contract by convention

### Context

A typed metadata-filtering DSL was considered for JSON metadata predicates.
That would be API surface promising more than it could keep delivering: every
future need — `OR`, `IN`, `LIKE`, array paths — would demand new cases and more
SQL-generation rules. It would become a mini-ORM rather than a thin vector-store
wrapper.

Separately, consumers had no way to keep **their own tables** in the store's
database file: the actor monopolizes the connection, and a second connection
cannot use vec0 (extension registration is per-connection and the `CSQLiteVec`
target is deliberately not exported).

### Decision

- No typed filter DSL is part of 0.1.0. Searches take a raw SQL fragment:
  `search(vector:topK:source:where:bindings:)` — post-filter around the KNN
  subquery (wrapped in a `MATERIALIZED` CTE: without it, SQLite's WHERE
  push-down moves the fragment into the KNN query, where vec0 rejects
  aux-column constraints) — and `searchText`/`searchHybrid` take the same
  parameters as plain WHERE conditions.
- General `query(_:bindings:)`/`execute(_:bindings:)` on the actor expose the
  connection (sqlite-vec loaded, actor-serialized) for the consumer's own
  tables, joins, and hand-written SQL. Values travel as `SQLValue`
  (`.int/.double/.text/.blob/.null`); rows come back as `SQLRow` with typed
  accessors.
- **Model where possible, convention where not:**
  - By model: bindings are typed; the lexical flag is schema-enforced (#5).
  - By convention (documented in README and doc-comments, not enforceable
    without SQL parsing): values must go through `bindings`, never
    interpolated; the vec0 table is a read contract — writes to it go through
    the typed API (raw writes bypass FTS sync and validation); `<table>_fts`
    is internal, never touched directly; no manual `BEGIN/COMMIT` around
    store methods.
- Consequence for semver (#4): the vec0 table's column layout is now part of
  the public API surface — consumers write SQL against it. Renaming or
  reshaping those columns is a major-version event.

### Revisit when

A recurring, well-shaped filtering idiom emerges in real usage — a thin typed
convenience *on top of* the SQL path could then earn its keep (it must compile
to the same mechanism, never replace it).

---

## 7. Maintenance APIs require measured consumer need

### Context

SQLite exposes useful maintenance operations (`VACUUM`, FTS optimize commands,
checkpointing, export/import patterns), and apps may eventually want package
level conveniences for them. Adding those methods too early would widen the
public API around behavior that is application-dependent and hard to make safe
without clear semantics.

### Decision

- Do not add maintenance APIs speculatively.
- Before adding one, require:
  - a real consumer need or benchmark/app-integration evidence;
  - safe semantics through the ``VectorStore`` actor;
  - tests that prove the behavior and failure modes;
  - no direct public write path to the internal FTS table;
  - no weakening of the raw-SQL conventions in #6.
- Prefer documenting `execute` recipes for consumer-owned tables before adding
  package-owned maintenance methods.

### Revisit when

Benchmarks or a real app show a repeatable maintenance problem that cannot be
handled cleanly through documented raw SQL conventions.
