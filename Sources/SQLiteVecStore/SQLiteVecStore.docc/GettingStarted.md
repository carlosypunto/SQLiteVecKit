# Getting Started

Build a small on-device RAG retrieval pipeline with `VectorStore`.

## Create a store

The `dimension` must equal your embedding model's output size, and it is
frozen into the database file on first creation:

<!-- Mirrors Snippets/CreatingAStore.swift (compile-checked by `swift build`). -->
```swift
let url = FileManager.default.temporaryDirectory.appendingPathComponent("vectors.db")

let store = try VectorStore(
    dbURL: url,                // or dbPath: String
    dimension: 512,            // MUST match your embedding model's output size
    distanceMetric: .cosine,   // default; .l2 for Euclidean distance
    tableName: "chunks",       // default; [A-Za-z_][A-Za-z0-9_]* only
    metadataByteLimit: VectorStore.defaultMetadataByteLimit,  // 16 KB per row
    lexicalSearch: true        // maintain the FTS5 index for searchText/searchHybrid
)
```

Reopening an existing file with a different configuration throws
``SQLiteError/schemaMismatch(expected:found:)`` — recreate the file and
re-ingest when your model or layout changes (see <doc:SchemaLifecycle>).

## Ingest chunks

Attach optional JSON metadata via any `Encodable` value (note the `encoding:`
label), and prefer `insertBatch` for ingestion — one transaction, all-or-nothing:

<!-- Mirrors Snippets/IngestingChunks.swift (compile-checked by `swift build`). -->
```swift
struct ChunkInfo: Codable {
    let page: Int
    let section: String
}

// One VectorEntry per chunk; `encoding:` JSON-encodes any Encodable for you.
let entries = try chunks.enumerated().map { index, chunk in
    try VectorEntry(
        id: index,
        content: chunk.text,
        source: "biology_notes.txt",
        encoding: ChunkInfo(page: chunk.page, section: "Cells"),
        vector: embed(chunk.text)
    )
}

// Single transaction, pre-validated, all-or-nothing.
try await store.insertBatch(entries)

// Or insert one row and let SQLite assign the id:
let newID = try await store.insert(
    content: "An extra chunk",
    source: "biology_notes.txt",
    vector: embed("An extra chunk")
)
```

## Search

Vector (semantic), lexical (exact terms), or hybrid — plus SQL filtering with
`where:`/`bindings:`:

<!-- Mirrors Snippets/Searching.swift (compile-checked by `swift build`). -->
```swift
// Semantic: embed the query with the SAME model used at ingestion.
let semantic = try await store.search(vector: embed(question), topK: 5)
for hit in semantic {
    print(hit.content, hit.distance)               // lower distance = more similar
    if let info = try hit.decodeMetadata(ChunkInfo.self) {
        print("page \(info.page)")
    }
}

// Lexical: FTS5 syntax — terms, "phrases", AND/OR/NOT, prefix*.
let lexical = try await store.searchText("mitochondria", topK: 5)

// Hybrid: RRF fusion of both lists; `score` is HIGHER = better.
let hybrid = try await store.searchHybrid(text: question, vector: embed(question), topK: 5)
```

The full tour of the three modes, their score semantics, and filtering lives
in <doc:SearchingAndFiltering>.

## Your own tables, raw SQL

The store's connection (with sqlite-vec loaded) is available for your own
tables in the same database file:

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
let author = rows.first?.text("author")   // typed accessors return Optionals
```

Read the conventions first: <doc:RawSQLConventions>.
