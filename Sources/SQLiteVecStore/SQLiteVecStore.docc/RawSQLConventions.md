# Raw SQL Conventions

Use the store's connection for your own tables — and know which lines not to
cross.

## Why raw SQL goes through the store

``VectorStore/query(_:bindings:)`` and ``VectorStore/execute(_:bindings:)``
run on the store's own connection, serialized by the actor, **with sqlite-vec
already loaded**. That last part matters: the extension is registered
per-connection and the C target is not exported, so a second connection you
open yourself cannot touch the vec0 table (`no such module: vec0`). If you
want your tables next to the vectors, this is the route.

<!-- Mirrors Snippets/OwnTables.swift (compile-checked by `swift build`). -->
```swift
try await store.execute("CREATE TABLE IF NOT EXISTS docs(name TEXT PRIMARY KEY, author TEXT)")
try await store.execute("INSERT INTO docs VALUES (?, ?)",
                        bindings: [.text("biology_notes.txt"), .text("Alice")])

let rows = try await store.query("""
    SELECT c.content, d.author
    FROM chunks c JOIN docs d ON d.name = c.source
    WHERE c.id = ?
    """, bindings: [.int(1)])

for row in rows {
    print(row.text("content") ?? "-", row.text("author") ?? "-")
}
```

`query` returns ``SQLRow`` values (subscript by column name → ``SQLValue``,
plus typed accessors `int`/`double`/`text`/`blob` returning Optionals — the
one pragmatic coercion is that `double(_:)` also accepts integer columns).
`execute` returns the number of rows changed.

## The conventions

These are enforced by documentation, not by the compiler (verifying them
would require parsing your SQL):

1. **Always bind values.** `?` placeholders + `bindings:` for every value;
   never interpolate data into the SQL string.
2. **The store's vec0 table is a read contract.** Query and join it freely —
   its column layout (`id`, `embedding`, `source`, `content`, `metadata`) is
   public API and only changes with a major version. But **write to it only
   through the typed API**: raw `INSERT`/`UPDATE`/`DELETE` bypass dimension
   and metadata validation *and* the FTS synchronization, silently desyncing
   lexical search.
3. **`<table>_fts` is internal.** Never read from or write to the companion
   FTS index directly; the store maintains it.
4. **Don't manage transactions manually** (`BEGIN`/`COMMIT` via `execute`)
   around store methods — the store wraps its own writes in transactions and
   a foreign transaction in flight will interfere.

## What you *can* do

Everything else: your own tables, indexes and views; joins against the vec0
table; `json_extract` reporting over metadata; even hand-written KNN SQL
(`WHERE embedding MATCH ? AND k = ?`) when the typed `search` doesn't fit.

For maintenance work, start with consumer-owned tables: your manifests,
document hashes, chunk counts, import logs, and app indexes are safe to update
through `execute`. Operations that mutate the store-owned vec0 table or its
FTS companion should stay behind the typed API unless SQLiteVecKit grows a
tested public method for that exact maintenance need.
