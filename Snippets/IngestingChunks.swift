// Ingest document chunks: Codable metadata via the `encoding:` label, batch
// inserts in a single transaction, and store-assigned ids.

// snippet.hide
import Foundation
import SQLiteVecStore

private func embed(_ text: String) -> [Float] { Array(repeating: 0, count: 512) }

func ingestingChunks(store: VectorStore, chunks: [(text: String, page: Int)]) async throws {
// snippet.show
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
// snippet.hide
    _ = newID
}
// snippet.show
