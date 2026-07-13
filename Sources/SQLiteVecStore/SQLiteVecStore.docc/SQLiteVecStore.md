# ``SQLiteVecStore``

On-device vector, lexical, and hybrid search backed by SQLite and sqlite-vec.

## Overview

`SQLiteVecStore` turns a plain SQLite file into a local retrieval engine for
iOS and macOS apps — no network, no external services. Embeddings live in a
[sqlite-vec](https://github.com/asg017/sqlite-vec) `vec0` virtual table; a
companion FTS5 index over the chunk text enables lexical (BM25) and hybrid
(Reciprocal Rank Fusion) retrieval; raw SQL access lets your own tables share
the database. On arm64, distance computations use sqlite-vec's NEON SIMD fast
paths.

The entire public API is the ``VectorStore`` actor:

```swift
let store = try VectorStore(dbURL: url, dimension: 512)
try await store.insertBatch(entries)
let hits = try await store.searchHybrid(text: question, vector: queryEmbedding, topK: 5)
```

Inline symbol documentation, articles, and snippets are versioned with the
source package. GitHub Pages shows the latest `main` documentation, while
SwiftPM consumers see the DocC catalog and Quick Help comments from the package
tag they depend on.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:EmbeddingSpaceManifests>
- ``VectorStore``
- ``VectorEntry``
- ``SearchResult``

### Creating a store

- ``VectorStore/init(dbPath:dimension:distanceMetric:tableName:metadataByteLimit:lexicalSearch:)``
- ``VectorStore/init(dbURL:dimension:distanceMetric:tableName:metadataByteLimit:lexicalSearch:)``
- ``DistanceMetric``

### Writing

- ``VectorStore/insert(_:)``
- ``VectorStore/insert(id:content:source:metadata:vector:)-4avgg``
- ``VectorStore/insert(content:source:metadata:vector:)-6hfvw``
- ``VectorStore/insertBatch(_:)``
- ``VectorStore/update(_:)``
- ``VectorStore/upsert(_:)``

### Retrieval

- <doc:SearchingAndFiltering>
- ``VectorStore/search(vector:topK:source:where:bindings:)-55qaw``
- ``VectorStore/searchText(_:topK:source:where:bindings:)``
- ``VectorStore/searchHybrid(text:vector:topK:source:where:bindings:)-9oyyp``
- ``HybridSearchResult``

### Reading and maintenance

- ``VectorStore/fetch(id:)``
- ``VectorStore/contains(id:)``
- ``VectorStore/count()``
- ``VectorStore/count(source:)``
- ``VectorStore/delete(id:)``
- ``VectorStore/delete(source:)``
- ``VectorStore/deleteAll()``

### Raw SQL

- <doc:RawSQLConventions>
- ``VectorStore/query(_:bindings:)``
- ``VectorStore/execute(_:bindings:)``
- ``SQLValue``
- ``SQLRow``

### Schema and errors

- <doc:SchemaLifecycle>
- ``SQLiteError``
