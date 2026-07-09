import Testing
import Foundation
import SQLiteVecStore

// MARK: - Metadata

@Suite("VectorStore.metadata")
struct MetadataTests {
    private struct ChunkInfo: Codable, Equatable {
        let page: Int
        let tags: [String]
    }

    @Test func rawJSONStringRoundTrips() async throws {
        try await withStore { store in
            let json = #"{"page":3}"#
            try await store.insert(id: 1, content: "x", source: "s", metadata: json, vector: [1, 0, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.metadata == json)
        }
    }

    @Test func codableMetadataRoundTrips() async throws {
        try await withStore { store in
            let info = ChunkInfo(page: 7, tags: ["swift", "sqlite"])
            let entry = try VectorEntry(id: 1, content: "x", source: "s", encoding: info, vector: [Float]([1, 0, 0]))
            try await store.insert(entry)
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(try results.first?.decodeMetadata(ChunkInfo.self) == info)
        }
    }

    @Test func missingMetadataIsNil() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.metadata == nil)
            #expect(try results.first?.decodeMetadata(ChunkInfo.self) == nil)
        }
    }

    @Test func updateReplacesMetadata() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", metadata: #"{"v":1}"#, vector: [1, 0, 0])
            try await store.update(VectorEntry(id: 1, content: "x", source: "s", metadata: #"{"v":2}"#, vector: [Float]([1, 0, 0])))
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.metadata == #"{"v":2}"#)
        }
    }

    @Test func updateCanClearMetadata() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", metadata: #"{"v":1}"#, vector: [1, 0, 0])
            try await store.update(VectorEntry(id: 1, content: "x", source: "s", vector: [Float]([1, 0, 0])))
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.metadata == nil)
        }
    }

    @Test func upsertReplacesMetadata() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", metadata: #"{"v":1}"#, vector: [1, 0, 0])
            try await store.upsert(VectorEntry(id: 1, content: "x", source: "s", metadata: #"{"v":2}"#, vector: [Float]([1, 0, 0])))
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.metadata == #"{"v":2}"#)
        }
    }

    @Test func oversizedMetadataThrows() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try VectorStore(dbPath: path, dimension: 3, metadataByteLimit: 8)
        do {
            try await store.insert(id: 1, content: "x", source: "s",
                                   metadata: "123456789", vector: [1, 0, 0])
            Issue.record("Expected metadataTooLarge")
        } catch let error as SQLiteError {
            guard case .metadataTooLarge(limit: 8, got: 9) = error else {
                Issue.record("Expected .metadataTooLarge(8, 9), got \(error)")
                return
            }
        }
        #expect(try await store.count() == 0)
    }

    @Test func oversizedMetadataInBatchWritesNothing() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try VectorStore(dbPath: path, dimension: 3, metadataByteLimit: 8)
        let batch = [
            VectorEntry(id: 1, content: "ok",  source: "s", metadata: "small", vector: [Float]([1, 0, 0])),
            VectorEntry(id: 2, content: "bad", source: "s", metadata: "123456789", vector: [Float]([0, 1, 0])),
        ]
        await #expect(throws: SQLiteError.self) {
            try await store.insertBatch(batch)
        }
        // Pre-scan rejects the batch before BEGIN: not even the valid row lands.
        #expect(try await store.count() == 0)
    }

    @Test func metadataLimitCountsUTF8Bytes() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try VectorStore(dbPath: path, dimension: 3, metadataByteLimit: 3)
        // "ñ" is 1 character but 2 UTF-8 bytes; "ññ" = 4 bytes > 3.
        await #expect(throws: SQLiteError.self) {
            try await store.insert(id: 1, content: "x", source: "s", metadata: "ññ", vector: [1, 0, 0])
        }
        try await store.insert(id: 1, content: "x", source: "s", metadata: "ñ", vector: [1, 0, 0])
    }
}
