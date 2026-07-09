import Testing
import SQLiteVecStore

// MARK: - Lexical search

@Suite("VectorStore.textSearch")
struct TextSearchTests {
    private func seed(_ store: VectorStore) async throws {
        try await store.insertBatch([
            VectorEntry(id: 1, content: "The mitochondria is the powerhouse of the cell",
                        source: "bio", vector: [Float]([1, 0, 0])),
            VectorEntry(id: 2, content: "Swift actors isolate mutable state",
                        source: "swift", vector: [Float]([0, 1, 0])),
            VectorEntry(id: 3, content: "The cell membrane controls what enters the cell",
                        source: "bio", vector: [Float]([0, 0, 1])),
        ])
    }

    @Test func findsExactKeyword() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.searchText("mitochondria")
            #expect(results.map(\.id) == [1])
        }
    }

    @Test func bm25RanksHigherTermFrequencyFirst() async throws {
        try await withStore { store in
            try await seed(store)
            // "cell" appears twice in row 3, once in row 1.
            let results = try await store.searchText("cell")
            #expect(results.first?.id == 3)
            #expect(results.count == 2)
            // BM25 scores are negative, ascending order = best first.
            #expect(results.allSatisfy { $0.distance < 0 })
        }
    }

    @Test func supportsFTS5QuerySyntax() async throws {
        try await withStore { store in
            try await seed(store)
            #expect(try await store.searchText("\"mutable state\"").map(\.id) == [2])
            #expect(try await store.searchText("cell NOT membrane").map(\.id) == [1])
            #expect(try await store.searchText("mitoch*").map(\.id) == [1])
        }
    }

    @Test func sourceFilterApplies() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.searchText("cell", source: "swift")
            #expect(results.isEmpty)
        }
    }

    @Test func respectsTopK() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.searchText("cell", topK: 1)
            #expect(results.count == 1)
        }
    }

    @Test func malformedQueryThrowsInvalidTextQuery() async throws {
        try await withStore { store in
            try await seed(store)
            do {
                _ = try await store.searchText("\"unbalanced")
                Issue.record("Expected invalidTextQuery")
            } catch let error as SQLiteError {
                guard case .invalidTextQuery = error else {
                    Issue.record("Expected .invalidTextQuery, got \(error)")
                    return
                }
            }
        }
    }

    @Test func indexTracksUpdateUpsertAndDelete() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "original wording", source: "s", vector: [1, 0, 0])

            try await store.update(VectorEntry(id: 1, content: "revised phrasing", source: "s", vector: [Float]([1, 0, 0])))
            #expect(try await store.searchText("original").isEmpty)
            #expect(try await store.searchText("revised").map(\.id) == [1])

            try await store.upsert(VectorEntry(id: 1, content: "upserted copy", source: "s", vector: [Float]([1, 0, 0])))
            #expect(try await store.searchText("revised").isEmpty)
            #expect(try await store.searchText("upserted").map(\.id) == [1])

            try await store.delete(id: 1)
            #expect(try await store.searchText("upserted").isEmpty)
        }
    }

    @Test func deleteAllClearsLexicalIndex() async throws {
        try await withStore { store in
            try await seed(store)
            try await store.deleteAll()
            #expect(try await store.searchText("cell").isEmpty)
        }
    }

    @Test func rollbackAlsoRollsBackLexicalIndex() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "existing", source: "s", vector: [1, 0, 0])
            let batch = [
                VectorEntry(id: 2, content: "brandnewterm", source: "s", vector: [Float]([0, 1, 0])),
                VectorEntry(id: 1, content: "duplicate", source: "s", vector: [Float]([0, 0, 1])),
            ]
            await #expect(throws: SQLiteError.self) {
                try await store.insertBatch(batch)
            }
            #expect(try await store.searchText("brandnewterm").isEmpty)
        }
    }
}

// MARK: - Hybrid search

@Suite("VectorStore.hybridSearch")
struct HybridSearchTests {
    @Test func doublyMatchedRowRanksFirst() async throws {
        try await withStore { store in
            try await store.insertBatch([
                // id 1: strong vector match AND contains the query term.
                VectorEntry(id: 1, content: "swift vector search", source: "s", vector: [Float]([1, 0, 0])),
                // id 2: strong vector match only.
                VectorEntry(id: 2, content: "unrelated words here", source: "s", vector: [Float]([0.95, 0.05, 0])),
                // id 3: lexical match only.
                VectorEntry(id: 3, content: "vector databases explained", source: "s", vector: [Float]([0, 0, 1])),
            ])
            let results = try await store.searchHybrid(text: "vector", vector: [1, 0, 0], topK: 3)
            #expect(results.first?.id == 1)
            #expect(results.first?.vectorRank != nil)
            #expect(results.first?.textRank != nil)
            #expect(results.count == 3)
        }
    }

    @Test func singleListMatchesHaveNilRankOnTheOtherSide() async throws {
        try await withStore { store in
            try await store.insertBatch([
                VectorEntry(id: 1, content: "alpha", source: "s", vector: [Float]([1, 0, 0])),
                VectorEntry(id: 2, content: "uniqueterm", source: "s", vector: [Float]([0, 1, 0])),
            ])
            let results = try await store.searchHybrid(text: "uniqueterm", vector: [1, 0, 0], topK: 5)
            let lexicalOnly = results.first { $0.id == 2 }
            #expect(lexicalOnly?.textRank == 1)
            #expect(results.allSatisfy { $0.score > 0 })
        }
    }

    @Test func resultsAreDeterministic() async throws {
        try await withStore { store in
            try await store.insertBatch([
                VectorEntry(id: 1, content: "term", source: "s", vector: [Float]([1, 0, 0])),
                VectorEntry(id: 2, content: "term", source: "s", vector: [Float]([1, 0, 0])),
            ])
            let a = try await store.searchHybrid(text: "term", vector: [1, 0, 0], topK: 2)
            let b = try await store.searchHybrid(text: "term", vector: [1, 0, 0], topK: 2)
            #expect(a == b)
            #expect(a.map(\.id) == [1, 2])  // identical scores tie-break by id
        }
    }
}
