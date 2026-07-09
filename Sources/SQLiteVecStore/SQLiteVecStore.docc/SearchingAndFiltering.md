# Searching and Filtering

Choose between vector, lexical, and hybrid retrieval, and narrow any of them
with SQL.

## The three retrieval modes

| Mode | Method | Finds | Ranking |
|---|---|---|---|
| Vector | ``VectorStore/search(vector:topK:source:where:bindings:)-55qaw`` | *Meaning* — paraphrases, related concepts | Distance (lower = better) |
| Lexical | ``VectorStore/searchText(_:topK:source:where:bindings:)`` | *Terms* — names, codes, acronyms, exact phrases | BM25 (negative; lower = better) |
| Hybrid | ``VectorStore/searchHybrid(text:vector:topK:source:where:bindings:)-9oyyp`` | Both, fused | RRF score (**higher** = better) |

Vector search misses exact terms ("error E1047" may not be near the query
embedding); lexical search misses paraphrases. Hybrid retrieval runs both and
fuses them, which is why RAG pipelines increasingly default to it.

<!-- Mirrors Snippets/Searching.swift (compile-checked by `swift build`). -->
```swift
// Semantic: embed the query with the SAME model used at ingestion.
let semantic = try await store.search(vector: embed(question), topK: 5)

// Lexical: FTS5 syntax — terms, "phrases", AND/OR/NOT, prefix*.
let lexical = try await store.searchText("mitochondria", topK: 5)

// Hybrid: RRF fusion of both lists; `score` is HIGHER = better.
let hybrid = try await store.searchHybrid(text: question, vector: embed(question), topK: 5)
for hit in hybrid {
    print(hit.content, hit.score, hit.vectorRank ?? "-", hit.textRank ?? "-")
}
```

## Score semantics — do not mix them

- ``SearchResult/distance`` from vector search: cosine `[0, 2]` or L2
  `[0, ∞)`, lower = more similar.
- ``SearchResult/distance`` from `searchText`: the BM25 score — negative,
  lower = better, comparable only within one query.
- ``HybridSearchResult/score``: Reciprocal Rank Fusion, **higher = better**.
  It lives on a separate type precisely so the two conventions can't be
  confused. `vectorRank`/`textRank` (1-based, `nil` when the row appeared in
  only one list) explain each row's position.

Hybrid fusion is rank-based (`score = Σ 1/(60 + rank)`) because a cosine
distance and a BM25 score cannot be meaningfully added or normalized. Both
underlying searches are overfetched to `min(topK × 4, maxTopK)` before fusing;
ties break by `id` so results are deterministic.

## Filtering with `where:` + `bindings:`

Every search accepts a SQL fragment. The one safety rule: **values always go
through `bindings` as `?` placeholders** — never interpolate them into the
fragment.

### Choosing filters

Prefer `source:` when you are scoping retrieval to one document, file, or
collection name. It is a vec0 metadata-column filter, so vector search applies
it inside the KNN query and `topK` counts only matching rows.

Use `where:` for post-filters and reporting-style predicates: JSON metadata,
date ranges, joins to your own tables, or conditions that may differ between
queries. In vector search, overfetch when recall matters:

<!-- Mirrors Snippets/FilteringWithSQL.swift (compile-checked by `swift build`). -->
```swift
// In `search` the fragment runs AFTER the KNN selection (post-filter):
// fewer than topK rows may come back — raise topK when filtering.
let filtered = try await store.search(
    vector: embed(question),
    topK: 20,
    where: "json_extract(metadata, '$.lang') = ? AND json_extract(metadata, '$.page') > ?",
    bindings: [.text("en"), .int(10)]
)
```

If your UI needs 5 filtered results, ask for a larger candidate set, then trim:

```swift
let candidates = try await store.search(
    vector: embed(question),
    topK: 50,
    where: "json_extract(metadata, '$.section') = ?",
    bindings: [.text("Cells")]
)
let visible = Array(candidates.prefix(5))
```

The fragment sees the columns `id`, `content`, `source`, `metadata`, and
`distance`. Anything SQLite can evaluate works: `json_extract` over the
metadata JSON, `LIKE`, `IN`, or subqueries against your own tables (see
<doc:RawSQLConventions>).

### Post-filter semantics in `search`

vec0 cannot filter auxiliary columns inside a KNN query, so the KNN picks its
`topK` neighbors **first** and the fragment filters **afterwards** — you may
receive fewer than `topK` rows (even zero). Raise `topK` when filtering.

In `searchText` the fragment is an ordinary WHERE condition with no such
caveat (qualify `content` as `c.content` there; the bare name is ambiguous
with the FTS index). In `searchHybrid` the same fragment is forwarded to both
the vector and FTS paths. Keep it valid in both contexts: unqualified `source`,
`metadata`, `id`, and `distance` work; qualify `content` only if the query is
text-only.

Rows without metadata never match `json_extract` predicates (`json_extract`
of NULL is NULL, which compares true with nothing).

## Scoping by document

All three methods accept `source:`. Unlike `where:`, this filter is applied
*inside* the KNN query (vec0 metadata column), so `topK` counts only matching
rows — no post-filter caveat.

## Cancellation

The API is `async` because ``VectorStore`` is an actor, but SQLite calls are
synchronous while they are executing on that actor. If a parent task is
cancelled before the actor starts work, normal Swift cancellation can prevent
the call from running. Once a SQLite step is in flight, SQLiteVecKit does not
currently call `sqlite3_interrupt`, so cancellation is observed only after that
operation returns.

For the intended small and medium local stores this is usually simpler and
more predictable than exposing interruption semantics prematurely. If a real
app shows visible cancellation latency at its corpus sizes, that behavior
needs a focused public API and tests around actor isolation.
