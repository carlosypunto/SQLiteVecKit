import Testing
import Foundation
import SQLiteVecStore

// MARK: - insert

@Suite("VectorStore.insert")
struct InsertTests {
    @Test func singleInsertSucceeds() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "hello", source: "doc", vector: [1, 0, 0])
        }
    }

    @Test func insertedRowIsSearchable() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "hello", source: "doc", vector: [1, 0, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.count == 1)
            #expect(results.first?.content == "hello")
            #expect(results.first?.source == "doc")
        }
    }

    @Test func duplicateIDThrows() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "first", source: "s", vector: [1, 0, 0])
            await #expect(throws: SQLiteError.self) {
                try await store.insert(id: 1, content: "second", source: "s", vector: [0, 1, 0])
            }
        }
    }

}

// MARK: - insertBatch

@Suite("VectorStore.insertBatch")
struct InsertBatchTests {
    @Test func emptyBatchIsNoOp() async throws {
        try await withStore { store in
            try await store.insertBatch([])
        }
    }

    @Test func batchInsertsAllRows() async throws {
        try await withStore { store in
            let entries = [
                VectorEntry(id: 1, content: "alpha", source: "s1", vector: [1, 0, 0]),
                VectorEntry(id: 2, content: "beta",  source: "s2", vector: [0, 1, 0]),
                VectorEntry(id: 3, content: "gamma", source: "s3", vector: [0, 0, 1]),
            ]
            try await store.insertBatch(entries)
            let results = try await store.search(vector: [1, 0, 0], topK: 10)
            #expect(results.count == 3)
        }
    }

    @Test func batchRollsBackOnDuplicateID() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "existing", source: "s", vector: [1, 0, 0])

            let batch = [
                VectorEntry(id: 2, content: "new",       source: "s", vector: [0, 1, 0]),
                VectorEntry(id: 1, content: "duplicate", source: "s", vector: [0, 0, 1]), // constraint violation
            ]
            await #expect(throws: SQLiteError.self) {
                try await store.insertBatch(batch)
            }

            // id=2 must not have been committed due to rollback
            let results = try await store.search(vector: [0, 1, 0], topK: 5)
            #expect(!results.contains(where: { $0.content == "new" }))
        }
    }

    @Test func largeBatchSucceeds() async throws {
        try await withStore(dimension: 4) { store in
            let entries = (1...100).map {
                VectorEntry(id: $0, content: "item \($0)", source: "src", vector: [Float($0), 0, 0, 0])
            }
            try await store.insertBatch(entries)
            let results = try await store.search(vector: [1, 0, 0, 0], topK: 100)
            #expect(results.count == 100)
        }
    }

    @Test func dimensionMismatchInBatchWritesNothing() async throws {
        try await withStore { store in
            let batch = [
                VectorEntry(id: 1, content: "ok",  source: "s", vector: [1, 0, 0]),
                VectorEntry(id: 2, content: "bad", source: "s", vector: [1, 0]),  // wrong dimension
            ]
            do {
                try await store.insertBatch(batch)
                Issue.record("Expected dimensionMismatch")
            } catch let error as SQLiteError {
                guard case .dimensionMismatch(expected: 3, got: 2) = error else {
                    Issue.record("Expected .dimensionMismatch(3, 2), got \(error)")
                    return
                }
            }
            // Pre-scan rejects the batch before BEGIN: not even the valid row lands.
            let results = try await store.search(vector: [1, 0, 0], topK: 10)
            #expect(results.isEmpty)
        }
    }
}

// MARK: - Auto-assigned ids

@Suite("VectorStore.autoID")
struct AutoIDTests {
    @Test func insertWithoutIdAssignsMonotonicIds() async throws {
        try await withStore { store in
            let first = try await store.insert(content: "a", source: "s", vector: [1, 0, 0])
            let second = try await store.insert(content: "b", source: "s", vector: [0, 1, 0])
            #expect(second > first)
            #expect(try await store.count() == 2)
            let fetched = try await store.fetch(id: first)
            #expect(fetched?.content == "a")
        }
    }

    @Test func autoIdContinuesAfterExplicitIds() async throws {
        try await withStore { store in
            try await store.insert(id: 100, content: "explicit", source: "s", vector: [1, 0, 0])
            let assigned = try await store.insert(content: "auto", source: "s", vector: [0, 1, 0])
            #expect(assigned > 100)
        }
    }
}

// MARK: - URL init & Codable

@Suite("VectorStore.conveniences")
struct ConvenienceTests {
    @Test func urlInitWorks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try VectorStore(dbURL: url, dimension: 3)
        try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
        #expect(try await store.count() == 1)
    }

    @Test func vectorEntryIsCodable() throws {
        let entry = VectorEntry(id: 1, content: "c", source: "s", metadata: #"{"a":1}"#, vector: [Float]([1, 0, 0]))
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VectorEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test func searchResultIsCodable() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            let data = try JSONEncoder().encode(results)
            let decoded = try JSONDecoder().decode([SearchResult].self, from: data)
            #expect(decoded == results)
        }
    }
}
