import Testing
import SQLiteVecStore

// MARK: - update

@Suite("VectorStore.update")
struct UpdateTests {
    @Test func updateReplacesContentSourceAndVector() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "old", source: "s1", vector: [1, 0, 0])
            try await store.update(VectorEntry(id: 1, content: "new", source: "s2", vector: [0, 1, 0]))

            let results = try await store.search(vector: [0, 1, 0], topK: 1)
            #expect(results.first?.content == "new")
            #expect(results.first?.source == "s2")
            #expect(abs((results.first?.distance ?? -1) - 0.0) < 1e-6)
        }
    }

    @Test func updateNonexistentIdThrowsRowNotFound() async throws {
        try await withStore { store in
            do {
                try await store.update(VectorEntry(id: 42, content: "x", source: "s", vector: [1, 0, 0]))
                Issue.record("Expected rowNotFound")
            } catch let error as SQLiteError {
                guard case .rowNotFound(id: 42) = error else {
                    Issue.record("Expected .rowNotFound(42), got \(error)")
                    return
                }
            }
        }
    }

    @Test func updateWithWrongDimensionThrows() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            await #expect(throws: SQLiteError.self) {
                try await store.update(VectorEntry(id: 1, content: "y", source: "s", vector: [1, 0]))
            }
        }
    }
}

// MARK: - upsert

@Suite("VectorStore.upsert")
struct UpsertTests {
    @Test func upsertNewIdInserts() async throws {
        try await withStore { store in
            try await store.upsert(VectorEntry(id: 1, content: "fresh", source: "s", vector: [1, 0, 0]))
            #expect(try await store.count() == 1)
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.content == "fresh")
        }
    }

    @Test func upsertExistingIdReplaces() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "old", source: "s", vector: [1, 0, 0])
            try await store.upsert(VectorEntry(id: 1, content: "replaced", source: "s", vector: [0, 1, 0]))
            #expect(try await store.count() == 1)
            let results = try await store.search(vector: [0, 1, 0], topK: 1)
            #expect(results.first?.content == "replaced")
        }
    }

    @Test func upsertWithWrongDimensionLeavesOldRowIntact() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "intact", source: "s", vector: [1, 0, 0])
            await #expect(throws: SQLiteError.self) {
                try await store.upsert(VectorEntry(id: 1, content: "bad", source: "s", vector: [1, 0]))
            }
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.content == "intact")
        }
    }
}

// MARK: - delete / deleteAll / contains

@Suite("VectorStore.delete")
struct DeleteTests {
    @Test func deleteRemovesRow() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            try await store.delete(id: 1)
            #expect(try await store.count() == 0)
            #expect(try await store.search(vector: [1, 0, 0], topK: 5).isEmpty)
        }
    }

    @Test func deleteNonexistentIdIsNoOp() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            try await store.delete(id: 99)
            #expect(try await store.count() == 1)
        }
    }

    @Test func reinsertAfterDeleteSucceeds() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "old", source: "s", vector: [1, 0, 0])
            try await store.delete(id: 1)
            try await store.insert(id: 1, content: "new", source: "s", vector: [0, 1, 0])
            let results = try await store.search(vector: [0, 1, 0], topK: 1)
            #expect(results.first?.content == "new")
        }
    }

    @Test func deleteAllEmptiesStoreAndKeepsItUsable() async throws {
        try await withStore { store in
            for i in 1...5 {
                try await store.insert(id: i, content: "c\(i)", source: "s", vector: [Float(i), 0, 0])
            }
            try await store.deleteAll()
            #expect(try await store.count() == 0)
            try await store.insert(id: 1, content: "after", source: "s", vector: [1, 0, 0])
            #expect(try await store.count() == 1)
        }
    }

    @Test func containsReflectsRowLifecycle() async throws {
        try await withStore { store in
            #expect(try await store.contains(id: 1) == false)
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            #expect(try await store.contains(id: 1) == true)
            try await store.delete(id: 1)
            #expect(try await store.contains(id: 1) == false)
        }
    }
}

// MARK: - fetch

@Suite("VectorStore.fetch")
struct FetchTests {
    @Test func fetchRoundTripsTheFullRow() async throws {
        try await withStore { store in
            let vector: [Float] = [0.25, -0.5, 0.125]
            try await store.insert(id: 7, content: "hello", source: "doc", metadata: #"{"p":1}"#, vector: vector)
            let entry = try await store.fetch(id: 7)
            #expect(entry == VectorEntry(id: 7, content: "hello", source: "doc", metadata: #"{"p":1}"#, vector: vector))
        }
    }

    @Test func fetchMissingIdReturnsNil() async throws {
        try await withStore { store in
            let fetched = try await store.fetch(id: 99)
            #expect(fetched == nil)
        }
    }

    @Test func fetchedVectorIsBitExact() async throws {
        try await withStore(dimension: 4) { store in
            let vector: [Float] = [1e-30, .pi, -0.1, 42.5]
            try await store.insert(id: 1, content: "x", source: "s", vector: vector)
            let fetched = try await store.fetch(id: 1)
            #expect(fetched?.vector == vector)
        }
    }
}
