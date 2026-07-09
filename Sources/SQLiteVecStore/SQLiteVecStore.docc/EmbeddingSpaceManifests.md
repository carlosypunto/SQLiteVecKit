# Embedding Space Manifests

Record the embedding space your app used to create a store, without making it
part of ``VectorStore``.

## Why the manifest lives outside the store

``VectorStore`` validates the SQLite schema it owns: vector dimension, distance
metric, table layout, and lexical-search companion table. It cannot know whether
two vectors were produced by the same model, tokenizer, language policy,
pooling strategy, or post-processing transform.

Keep that contract in a consumer-owned table. On app startup, read it before
querying. If it no longer matches the embedder your app is about to use, create
a new database or delete and re-ingest from source content.

Fields that should invalidate the index include:

- model identifier and model revision;
- dimension;
- distance metric;
- language strategy;
- pooling strategy;
- transform identifier and version;
- optional centroid or transform-input hash, when using mean-centering or a
  similar corpus-derived transform.

Changing any of those fields means old and new vectors no longer occupy the
same embedding space. SQLiteVecKit cannot migrate that because it does not own
the original documents, chunker, embedder, or transform pipeline.

## Example

<!-- Mirrors Snippets/EmbeddingSpaceManifest.swift (compile-checked by `swift build`). -->
```swift
struct EmbeddingSpaceManifest: Codable, Equatable, Sendable {
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

let manifest = EmbeddingSpaceManifest(
    modelID: "com.example.LocalEmbedding",
    modelRevision: "v1",
    dimension: 512,
    distanceMetric: DistanceMetric.cosine.rawValue,
    languageStrategy: "english-only",
    poolingStrategy: "mean-token-pooling",
    transformID: "mean-centering",
    transformVersion: "v1",
    centroidHash: "sha256:7f4b..."
)

try await store.execute("""
    CREATE TABLE IF NOT EXISTS embedding_space_manifest(
        key TEXT PRIMARY KEY CHECK (key = 'current'),
        json TEXT NOT NULL
    )
    """)

let data = try JSONEncoder().encode(manifest)
let json = String(decoding: data, as: UTF8.self)

try await store.execute("""
    INSERT OR REPLACE INTO embedding_space_manifest(key, json)
    VALUES ('current', ?)
    """, bindings: [.text(json)])

let rows = try await store.query("SELECT json FROM embedding_space_manifest WHERE key = 'current'")
if let savedJSON = rows.first?.text("json") {
    let saved = try JSONDecoder().decode(
        EmbeddingSpaceManifest.self,
        from: Data(savedJSON.utf8)
    )
    precondition(saved == manifest)
}
```

The table is ordinary application data. You can version it differently, split
columns instead of storing JSON, or keep one row per collection. The important
part is that your app compares it before mixing old stored vectors with a new
embedding pipeline.
