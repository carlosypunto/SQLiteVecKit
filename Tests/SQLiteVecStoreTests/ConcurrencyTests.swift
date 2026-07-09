import Testing
import SQLiteVecStore

// MARK: - Concurrency

@Suite("VectorStore.concurrency")
struct ConcurrencyTests {
    @Test("VectorStore.concurrency concurrent reads after batch insert")
    func concurrentReadsAfterBatchInsert() async throws {
        try await withStore(dimension: 2) { store in
            let entries = (1...40).map { id in
                VectorEntry(
                    id: id,
                    content: "shared term \(id)",
                    source: id.isMultiple(of: 2) ? "even" : "odd",
                    vector: [Float(id), Float(40 - id)]
                )
            }
            try await store.insertBatch(entries)

            let ids = try await withThrowingTaskGroup(of: Int.self) { group in
                for id in 1...40 {
                    group.addTask {
                        let fetched = try await store.fetch(id: id)
                        #expect(fetched?.id == id)
                        #expect(try await store.contains(id: id))
                        #expect(try await store.count(source: id.isMultiple(of: 2) ? "even" : "odd") == 20)
                        return fetched?.id ?? -1
                    }
                }

                var fetchedIDs: [Int] = []
                for try await id in group {
                    fetchedIDs.append(id)
                }
                return fetchedIDs.sorted()
            }

            #expect(ids == Array(1...40))
        }
    }

    @Test("VectorStore.concurrency concurrent inserts all land")
    func concurrentInsertsFromMultipleTasksAllLand() async throws {
        try await withStore(dimension: 2) { store in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in 0..<8 {
                    group.addTask {
                        for offset in 1...10 {
                            let id = worker * 100 + offset
                            try await store.insert(
                                id: id,
                                content: "worker \(worker) item \(offset)",
                                source: "worker-\(worker)",
                                vector: [Float(worker + 1), Float(offset)]
                            )
                        }
                    }
                }

                try await group.waitForAll()
            }

            #expect(try await store.count() == 80)
            for worker in 0..<8 {
                #expect(try await store.count(source: "worker-\(worker)") == 10)
            }
        }
    }
}
