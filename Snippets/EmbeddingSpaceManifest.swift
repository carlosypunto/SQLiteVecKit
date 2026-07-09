// Store an embedding-space manifest in a consumer-owned table. The manifest is
// application policy, not VectorStore state.

// snippet.hide
import Foundation
import SQLiteVecStore

func embeddingSpaceManifest(store: VectorStore) async throws {
// snippet.show
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
    modelRevision: "2026-07-01",
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
// snippet.hide
}
// snippet.show
