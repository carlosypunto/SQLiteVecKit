import Testing
import SQLiteVecStore

// MARK: - Source-level operations

@Suite("VectorStore.sourceOps")
struct SourceOpsTests {
    @Test func deleteSourceRemovesOnlyThatSource() async throws {
        try await withStore { store in
            try await store.insertBatch([
                VectorEntry(id: 1, content: "a1", source: "a", vector: [Float]([1, 0, 0])),
                VectorEntry(id: 2, content: "b1", source: "b", vector: [Float]([0, 1, 0])),
                VectorEntry(id: 3, content: "a2", source: "a", vector: [Float]([0, 0, 1])),
            ])
            try await store.delete(source: "a")
            #expect(try await store.count() == 1)
            #expect(try await store.contains(id: 2))
        }
    }

    @Test func deleteMissingSourceIsNoOp() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            try await store.delete(source: "zzz")
            #expect(try await store.count() == 1)
        }
    }

    @Test func countBySource() async throws {
        try await withStore { store in
            try await store.insertBatch([
                VectorEntry(id: 1, content: "a1", source: "a", vector: [Float]([1, 0, 0])),
                VectorEntry(id: 2, content: "b1", source: "b", vector: [Float]([0, 1, 0])),
                VectorEntry(id: 3, content: "a2", source: "a", vector: [Float]([0, 0, 1])),
            ])
            #expect(try await store.count(source: "a") == 2)
            #expect(try await store.count(source: "b") == 1)
            #expect(try await store.count(source: "zzz") == 0)
        }
    }

    @Test func deleteSourceAlsoDropsLexicalIndexEntries() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "unique keyword", source: "a", vector: [1, 0, 0])
            try await store.delete(source: "a")
            #expect(try await store.searchText("keyword").isEmpty)
        }
    }
}

// MARK: - count

@Suite("VectorStore.count")
struct CountTests {
    @Test func countTracksMutations() async throws {
        try await withStore { store in
            #expect(try await store.count() == 0)
            try await store.insert(id: 1, content: "a", source: "s", vector: [1, 0, 0])
            #expect(try await store.count() == 1)
            try await store.insertBatch([
                VectorEntry(id: 2, content: "b", source: "s", vector: [0, 1, 0]),
                VectorEntry(id: 3, content: "c", source: "s", vector: [0, 0, 1]),
            ])
            #expect(try await store.count() == 3)
            try await store.delete(id: 2)
            #expect(try await store.count() == 2)
        }
    }
}
