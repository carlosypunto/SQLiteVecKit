import Testing
import SQLiteVecStore

// MARK: - search

@Suite("VectorStore.search")
struct SearchTests {
    @Test func emptyStoreReturnsEmpty() async throws {
        try await withStore { store in
            let results = try await store.search(vector: [1, 0, 0], topK: 5)
            #expect(results.isEmpty)
        }
    }

    @Test func returnsClosestFirst() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "far",   source: "s", vector: [0, 0, 1])
            try await store.insert(id: 2, content: "close", source: "s", vector: [1, 0, 0])

            let results = try await store.search(vector: [1, 0, 0], topK: 2)
            #expect(results.first?.content == "close")
        }
    }

    @Test func distancesAreNonDecreasing() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "a", source: "s", vector: [1.0, 0.0, 0.0])
            try await store.insert(id: 2, content: "b", source: "s", vector: [0.5, 0.5, 0.0])
            try await store.insert(id: 3, content: "c", source: "s", vector: [0.0, 0.0, 1.0])

            let results = try await store.search(vector: [1, 0, 0], topK: 3)
            let distances = results.map(\.distance)
            #expect(distances == distances.sorted())
        }
    }

    @Test func respectsTopKLimit() async throws {
        try await withStore { store in
            for i in 1...10 {
                try await store.insert(id: i, content: "item\(i)", source: "s", vector: [Float(i), 0, 0])
            }
            let results = try await store.search(vector: [1, 0, 0], topK: 3)
            #expect(results.count == 3)
        }
    }

    @Test func topKExceedingRowCountReturnsAll() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "only", source: "s", vector: [1, 0, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 100)
            #expect(results.count == 1)
        }
    }

    @Test func searchReturnsRowId() async throws {
        try await withStore { store in
            try await store.insert(id: 7, content: "seven", source: "s", vector: [1, 0, 0])
            try await store.insert(id: 9, content: "nine",  source: "s", vector: [0, 1, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 2)
            #expect(results.map(\.id) == [7, 9])
        }
    }

    @Test func dimensionMismatchOnInsert() async throws {
        try await withStore { store in
            do {
                try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0, 0])
                Issue.record("Expected dimensionMismatch")
            } catch let error as SQLiteError {
                guard case .dimensionMismatch(expected: 3, got: 4) = error else {
                    Issue.record("Expected .dimensionMismatch(3, 4), got \(error)")
                    return
                }
            }
        }
    }

    @Test func dimensionMismatchOnSearch() async throws {
        try await withStore { store in
            await #expect(throws: SQLiteError.self) {
                _ = try await store.search(vector: [1, 0], topK: 1)
            }
        }
    }

    @Test(arguments: [0, -1, 4097])
    func invalidTopKThrows(_ topK: Int) async throws {
        try await withStore { store in
            do {
                _ = try await store.search(vector: [1, 0, 0], topK: topK)
                Issue.record("Expected invalidTopK for \(topK)")
            } catch let error as SQLiteError {
                guard case .invalidTopK(topK) = error else {
                    Issue.record("Expected .invalidTopK(\(topK)), got \(error)")
                    return
                }
            }
        }
    }

    @Test func topKAtMaxIsAccepted() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "only", source: "s", vector: [1, 0, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: VectorStore.maxTopK)
            #expect(results.count == 1)
        }
    }

    @Test func cosineDistancesMatchExpectedValues() async throws {
        try await withStore { store in
            // Default metric is cosine: orthogonal vectors → distance 1, same direction → 0.
            try await store.insert(id: 1, content: "same", source: "s", vector: [1, 0, 0])
            try await store.insert(id: 2, content: "orthogonal", source: "s", vector: [0, 1, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 2)
            #expect(results.count == 2)
            #expect(abs(results[0].distance - 0.0) < 1e-6)
            #expect(abs(results[1].distance - 1.0) < 1e-6)
        }
    }

    @Test func exactMatchHasZeroDistance() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "x", source: "s", vector: [1, 0, 0])
            let results = try await store.search(vector: [1, 0, 0], topK: 1)
            #expect(results.first?.distance == 0.0)
        }
    }

}

// MARK: - Filtered search

@Suite("VectorStore.filteredSearch")
struct FilteredSearchTests {
    private func seed(_ store: VectorStore) async throws {
        try await store.insertBatch([
            VectorEntry(id: 1, content: "doc-a-1", source: "a", vector: [1, 0, 0]),
            VectorEntry(id: 2, content: "doc-b-1", source: "b", vector: [0.9, 0.1, 0]),
            VectorEntry(id: 3, content: "doc-a-2", source: "a", vector: [0, 1, 0]),
            VectorEntry(id: 4, content: "doc-b-2", source: "b", vector: [0, 0, 1]),
        ])
    }

    @Test func filterReturnsOnlyMatchingSource() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(vector: [1, 0, 0], topK: 10, source: "a")
            #expect(results.map(\.id) == [1, 3])
            #expect(results.allSatisfy { $0.source == "a" })
        }
    }

    @Test func filterWithNoMatchesReturnsEmpty() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(vector: [1, 0, 0], topK: 10, source: "zzz")
            #expect(results.isEmpty)
        }
    }

    @Test func topKAppliesWithinFilter() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(vector: [1, 0, 0], topK: 1, source: "b")
            #expect(results.count == 1)
            #expect(results.first?.id == 2)  // closest source-b row
        }
    }

    @Test func nilSourceSearchesEverything() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(vector: [1, 0, 0], topK: 10)
            #expect(results.count == 4)
        }
    }
}

// MARK: - SQL where-fragment filtering

@Suite("VectorStore.whereFilters")
struct WhereFilterTests {
    private func seed(_ store: VectorStore) async throws {
        try await store.insertBatch([
            VectorEntry(id: 1, content: "page one", source: "doc",
                        metadata: #"{"page": 1, "lang": "en", "draft": true}"#, vector: [Float]([1, 0, 0])),
            VectorEntry(id: 2, content: "page two", source: "doc",
                        metadata: #"{"page": 2, "lang": "es", "draft": false}"#, vector: [Float]([0.9, 0.1, 0])),
            VectorEntry(id: 3, content: "no metadata", source: "doc", vector: [Float]([0.8, 0.2, 0])),
        ])
    }

    @Test func jsonNumberEquality() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(vector: [1, 0, 0], topK: 10,
                                                 where: "json_extract(metadata, '$.page') = ?",
                                                 bindings: [.int(2)])
            #expect(results.map(\.id) == [2])
        }
    }

    @Test func jsonStringEqualityAndComparison() async throws {
        try await withStore { store in
            try await seed(store)
            let en = try await store.search(vector: [1, 0, 0], topK: 10,
                                            where: "json_extract(metadata, '$.lang') = ?",
                                            bindings: [.text("en")])
            #expect(en.map(\.id) == [1])
            let above = try await store.search(vector: [1, 0, 0], topK: 10,
                                               where: "json_extract(metadata, '$.page') > ?",
                                               bindings: [.int(1)])
            #expect(above.map(\.id) == [2])
        }
    }

    @Test func jsonBoolFilter() async throws {
        try await withStore { store in
            try await seed(store)
            // json_extract surfaces JSON booleans as integers 0/1.
            let drafts = try await store.search(vector: [1, 0, 0], topK: 10,
                                                where: "json_extract(metadata, '$.draft') = ?",
                                                bindings: [.int(1)])
            #expect(drafts.map(\.id) == [1])
        }
    }

    @Test func compoundFragmentWithAND() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(
                vector: [1, 0, 0], topK: 10,
                where: "json_extract(metadata, '$.lang') = ? AND json_extract(metadata, '$.page') = ?",
                bindings: [.text("en"), .int(2)]
            )
            #expect(results.isEmpty)
        }
    }

    @Test func fragmentCanUseNonMetadataColumns() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(vector: [1, 0, 0], topK: 10,
                                                 where: "id > ? AND metadata IS NOT NULL",
                                                 bindings: [.int(1)])
            #expect(results.map(\.id) == [2])
        }
    }

    @Test func rowsWithoutMetadataNeverMatchJSONFilters() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.search(vector: [1, 0, 0], topK: 10,
                                                 where: "json_extract(metadata, '$.page') != ?",
                                                 bindings: [.int(99)])
            #expect(!results.map(\.id).contains(3))
        }
    }

    @Test func malformedFragmentThrows() async throws {
        try await withStore { store in
            try await seed(store)
            await #expect(throws: SQLiteError.self) {
                _ = try await store.search(vector: [1, 0, 0], topK: 5,
                                           where: "NOT VALID SQL ???")
            }
        }
    }

    @Test func fragmentAppliesToTextSearch() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.searchText("page",
                                                     where: "json_extract(metadata, '$.lang') = ?",
                                                     bindings: [.text("es")])
            #expect(results.map(\.id) == [2])
        }
    }

    @Test func fragmentAppliesToHybridSearch() async throws {
        try await withStore { store in
            try await seed(store)
            let results = try await store.searchHybrid(text: "page", vector: [1, 0, 0], topK: 5,
                                                       where: "json_extract(metadata, '$.lang') = ?",
                                                       bindings: [.text("es")])
            #expect(results.map(\.id) == [2])
        }
    }

    @Test func postFilterMayReturnFewerThanTopK() async throws {
        try await withStore { store in
            try await seed(store)
            // KNN with topK 1 picks the closest row (id 1), then the fragment
            // discards it — documented post-filter semantics.
            let results = try await store.search(vector: [1, 0, 0], topK: 1,
                                                 where: "json_extract(metadata, '$.page') = ?",
                                                 bindings: [.int(2)])
            #expect(results.isEmpty)
        }
    }
}

// MARK: - [Double] overloads

@Suite("VectorStore.doubleVectors")
struct DoubleVectorTests {
    @Test func entryInitConvertsDoubles() {
        let doubles: [Double] = [0.25, 0.5, 0.75]
        let entry = VectorEntry(id: 1, content: "x", source: "s", vector: doubles)
        #expect(entry.vector == doubles.map(Float.init))
    }

    @Test func doubleSearchMatchesFloatSearch() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "a", source: "s", vector: [Float]([1, 0, 0]))
            try await store.insert(id: 2, content: "b", source: "s", vector: [Float]([0, 1, 0]))

            let fromFloats  = try await store.search(vector: [Float]([1, 0, 0]), topK: 2)
            let fromDoubles = try await store.search(vector: [Double]([1, 0, 0]), topK: 2)
            #expect(fromFloats == fromDoubles)
        }
    }

    @Test func doubleInsertIsSearchable() async throws {
        try await withStore { store in
            try await store.insert(id: 1, content: "hello", source: "doc", vector: [Double]([1, 0, 0]))
            let results = try await store.search(vector: [Float]([1, 0, 0]), topK: 1)
            #expect(results.first?.content == "hello")
            #expect(results.first?.distance == 0.0)
        }
    }
}
