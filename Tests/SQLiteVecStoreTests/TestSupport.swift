import Foundation
import SQLiteVecStore

// Shared helpers for the VectorStore test files.

func tmpPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".sqlite")
        .path
}

func withStore(
    dimension: Int = 3,
    _ body: (VectorStore) async throws -> Void
) async throws {
    let path = tmpPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try VectorStore(dbPath: path, dimension: dimension)
    try await body(store)
}
