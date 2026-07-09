# Schema Lifecycle

What gets frozen into the database file, when `schemaMismatch` fires, and how
to "migrate".

## What the file remembers

The first time a store creates its database file, the whole configuration is
frozen into it:

- `dimension` — the embedding column is `FLOAT[N]`.
- `distanceMetric` — emitted in the DDL (`distance_metric=cosine`/`l2`).
- The column layout (`id`, `embedding`, `source`, `+content`, `+metadata`).
- `lexicalSearch` — whether the companion FTS5 index exists.

On every subsequent open, the initializer reads the actual DDL back from
`sqlite_master`, normalizes it, and compares it against what the current
configuration would generate. Any difference throws
``SQLiteError/schemaMismatch(expected:found:)`` **at init time** — the store
never silently reuses a table with a different shape. (A plain
`CREATE VIRTUAL TABLE IF NOT EXISTS` would do exactly that silent reuse,
which is why the explicit comparison exists.)

## Every path to `schemaMismatch`

| You did | Result |
|---|---|
| Reopened with a different `dimension` | Mismatch (embedding column differs) |
| Reopened with a different `distanceMetric` | Mismatch |
| Reopened with the opposite `lexicalSearch` value | Mismatch, both directions |
| Opened a file created with a different table layout | Mismatch |
| Opened a file where only one of the two tables exists | Mismatch — silently creating an empty FTS index next to populated vector rows would leave lexical search blind to them |
| Hand-edited the DDL | Mismatch (correctly) |

## How to "migrate"

There is deliberately **no automatic migration**. Changing `dimension` or
`distanceMetric` requires *re-embedding* every chunk with the new model
configuration. The same is true when your model revision, language strategy,
pooling strategy, or transform pipeline changes. The store only holds the
resulting vectors — it cannot regenerate them. The honest procedure:

1. Keep your source content (documents/chunks) outside the store, or export
   what you need first (`fetch(id:)` returns full rows;
   ``VectorStore/query(_:bindings:)`` can dump whole tables; `VectorEntry` is
   `Codable`).
2. Delete the database file.
3. Create the store with the new configuration and re-ingest with
   ``VectorStore/insertBatch(_:)``.

For per-document updates (a source file changed), you don't need any of this:
``VectorStore/delete(source:)`` + `insertBatch` replaces one document's chunks
in place.

## Per-document re-ingestion

Treat `source` as the document-level re-ingestion key when that fits your app:

1. Detect a changed document in your own catalog.
2. Chunk and embed the new content outside SQLiteVecKit.
3. Call ``VectorStore/delete(source:)`` for the document.
4. Call ``VectorStore/insertBatch(_:)`` with the new chunks.

For larger apps, keep a consumer-owned `indexed_documents` table with the
document id or path, content hash, chunk count, embedding-space manifest
version, and last indexed date. That table tells your app what is stale; the
store remains responsible only for storing and retrieving chunks.

Document content changes are local re-ingests. Embedding-space changes are
global: create a new database or clear and rebuild the whole store from source
content.
