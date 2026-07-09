// Create (or open) a vector store. The configuration is frozen into the
// database file on first creation.

// snippet.hide
import Foundation
import SQLiteVecStore

func creatingAStore() async throws {
// snippet.show
let url = FileManager.default.temporaryDirectory.appendingPathComponent("vectors.db")

let store = try VectorStore(
    dbURL: url,                // or dbPath: String
    dimension: 512,            // MUST match your embedding model's output size
    distanceMetric: .cosine,   // default; .l2 for Euclidean distance
    tableName: "chunks",       // default; [A-Za-z_][A-Za-z0-9_]* only
    metadataByteLimit: VectorStore.defaultMetadataByteLimit,  // 16 KB per row
    lexicalSearch: true        // maintain the FTS5 index for searchText/searchHybrid
)

let rows = try await store.count()
// snippet.hide
    _ = rows
}
// snippet.show
