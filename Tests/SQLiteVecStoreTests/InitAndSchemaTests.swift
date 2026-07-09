import Testing
import Foundation
import CSQLiteVec
import SQLiteVecStore

// MARK: - VectorStore init

@Suite("VectorStore.init")
struct InitTests {
    @Test func succeedsWithValidPath() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try VectorStore(dbPath: path, dimension: 3)
    }

    @Test func createsDatabaseFile() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try VectorStore(dbPath: path, dimension: 3)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func failsWithNonExistentDirectory() {
        #expect(throws: SQLiteError.self) {
            _ = try VectorStore(dbPath: "/nonexistent_dir_\(UUID().uuidString)/db.sqlite")
        }
    }

    @Test func acceptsArbitraryDimensions() throws {
        for dim in [1, 16, 512, 1536] {
            let path = tmpPath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            _ = try VectorStore(dbPath: path, dimension: dim)
        }
    }

    @Test(arguments: [0, -1])
    func invalidDimensionThrows(_ dimension: Int) {
        do {
            _ = try VectorStore(dbPath: tmpPath(), dimension: dimension)
            Issue.record("Expected invalidDimension for \(dimension)")
        } catch let error as SQLiteError {
            guard case .invalidDimension(dimension) = error else {
                Issue.record("Expected .invalidDimension(\(dimension)), got \(error)")
                return
            }
        } catch {
            Issue.record("Expected SQLiteError, got \(error)")
        }
    }

    @Test func explicitL2MetricSucceeds() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try VectorStore(dbPath: path, dimension: 3, distanceMetric: .l2)
    }

    @Test func customTableNameRoundTrips() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try VectorStore(
            dbPath: path,
            dimension: 3,
            tableName: "embeddings"
        )
        try await store.insert(id: 1, content: "hello", source: "doc", vector: [1, 0, 0])
        let results = try await store.search(vector: [1, 0, 0], topK: 1)
        #expect(results.first?.content == "hello")
    }

    @Test(arguments: ["my table", "1abc", "a;drop", "", "tabla-con-guion"])
    func invalidTableNameThrows(_ name: String) {
        do {
            _ = try VectorStore(dbPath: tmpPath(), dimension: 3, tableName: name)
            Issue.record("Expected invalidTableName for '\(name)'")
        } catch let error as SQLiteError {
            guard case .invalidTableName = error else {
                Issue.record("Expected .invalidTableName, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected SQLiteError, got \(error)")
        }
    }

    @Test func bundledVecVersionIsExposed() {
        #expect(VectorStore.bundledVecVersion == "v0.1.9")
    }
}

// MARK: - Schema mismatch detection

@Suite("VectorStore.schemaMismatch")
struct SchemaMismatchTests {
    private func expectSchemaMismatch(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected .schemaMismatch")
        } catch let error as SQLiteError {
            guard case .schemaMismatch = error else {
                Issue.record("Expected .schemaMismatch, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected SQLiteError, got \(error)")
        }
    }

    @Test func differentDimensionThrows() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do { _ = try VectorStore(dbPath: path, dimension: 3) }
        expectSchemaMismatch {
            _ = try VectorStore(dbPath: path, dimension: 4)
        }
    }

    @Test func differentMetricThrows() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do { _ = try VectorStore(dbPath: path, dimension: 3, distanceMetric: .cosine) }
        expectSchemaMismatch {
            _ = try VectorStore(dbPath: path, dimension: 3, distanceMetric: .l2)
        }
    }

    @Test func identicalConfigReopensAndKeepsRows() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try VectorStore(dbPath: path, dimension: 3)
            try await store.insert(id: 1, content: "persisted", source: "s", vector: [1, 0, 0])
        }
        let reopened = try VectorStore(dbPath: path, dimension: 3)
        let results = try await reopened.search(vector: [1, 0, 0], topK: 1)
        #expect(results.first?.content == "persisted")
    }

    @Test func legacyV1SchemaIsDetected() throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Simulate a database created by the pre-v2 wrapper (metadata `content`,
        // no explicit distance_metric) using the raw C API.
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite_vec_bootstrap(db) == SQLITE_OK)
        let legacyDDL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING vec0(
                id INTEGER PRIMARY KEY,
                content TEXT,
                source TEXT,
                embedding FLOAT[3]
            );
        """
        #expect(sqlite3_exec(db, legacyDDL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        expectSchemaMismatch {
            _ = try VectorStore(dbPath: path, dimension: 3)
        }
    }
}

// MARK: - Lexical search flag

@Suite("VectorStore.lexicalFlag")
struct LexicalFlagTests {
    @Test func disabledStoreCreatesNoFTSTableAndStillWorks() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try VectorStore(dbPath: path, dimension: 3, lexicalSearch: false)
        try await store.insert(id: 1, content: "hello", source: "s", vector: [1, 0, 0])
        try await store.update(VectorEntry(id: 1, content: "updated", source: "s", vector: [Float]([1, 0, 0])))
        try await store.upsert(VectorEntry(id: 1, content: "upserted", source: "s", vector: [Float]([0, 1, 0])))
        try await store.delete(id: 1)
        try await store.insert(id: 2, content: "x", source: "s", vector: [1, 0, 0])
        try await store.deleteAll()
        try await store.insert(id: 3, content: "y", source: "s2", vector: [1, 0, 0])
        try await store.delete(source: "s2")
        #expect(try await store.count() == 0)

        let fts = try await store.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
            bindings: [.text("chunks_fts")]
        )
        #expect(fts.isEmpty)
    }

    @Test func textAndHybridSearchThrowWhenDisabled() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try VectorStore(dbPath: path, dimension: 3, lexicalSearch: false)
        try await store.insert(id: 1, content: "hello", source: "s", vector: [1, 0, 0])

        do {
            _ = try await store.searchText("hello")
            Issue.record("Expected lexicalSearchDisabled from searchText")
        } catch let error as SQLiteError {
            guard case .lexicalSearchDisabled = error else {
                Issue.record("Expected .lexicalSearchDisabled, got \(error)")
                return
            }
        }

        do {
            _ = try await store.searchHybrid(text: "hello", vector: [1, 0, 0])
            Issue.record("Expected lexicalSearchDisabled from searchHybrid")
        } catch let error as SQLiteError {
            guard case .lexicalSearchDisabled = error else {
                Issue.record("Expected .lexicalSearchDisabled, got \(error)")
                return
            }
        }
    }

    @Test func flagIsFrozenIntoTheFileBothDirections() async throws {
        // Created ON, reopened OFF.
        let pathOn = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: pathOn) }
        do { _ = try VectorStore(dbPath: pathOn, dimension: 3, lexicalSearch: true) }
        #expect(throws: SQLiteError.self) {
            _ = try VectorStore(dbPath: pathOn, dimension: 3, lexicalSearch: false)
        }

        // Created OFF, reopened ON.
        let pathOff = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: pathOff) }
        do { _ = try VectorStore(dbPath: pathOff, dimension: 3, lexicalSearch: false) }
        #expect(throws: SQLiteError.self) {
            _ = try VectorStore(dbPath: pathOff, dimension: 3, lexicalSearch: true)
        }
    }

    @Test func disabledStoreReopensDisabled() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let store = try VectorStore(dbPath: path, dimension: 3, lexicalSearch: false)
            try await store.insert(id: 1, content: "persisted", source: "s", vector: [1, 0, 0])
        }
        let reopened = try VectorStore(dbPath: path, dimension: 3, lexicalSearch: false)
        #expect(try await reopened.count() == 1)
    }
}

// MARK: - Legacy schema without FTS companion

@Suite("VectorStore.ftsSchemaMigration")
struct FTSSchemaTests {
    @Test func vecTableWithoutFTSCompanionIsRejected() async throws {
        let path = tmpPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Simulate a database created before lexical search existed: current
        // vec0 layout, but no companion FTS table.
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        #expect(sqlite_vec_bootstrap(db) == SQLITE_OK)
        let preFTSDDL = """
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING vec0(
                id INTEGER PRIMARY KEY,
                embedding FLOAT[3] distance_metric=cosine,
                source TEXT,
                +content TEXT,
                +metadata TEXT
            );
        """
        #expect(sqlite3_exec(db, preFTSDDL, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        do {
            _ = try VectorStore(dbPath: path, dimension: 3)
            Issue.record("Expected .schemaMismatch")
        } catch let error as SQLiteError {
            guard case .schemaMismatch = error else {
                Issue.record("Expected .schemaMismatch, got \(error)")
                return
            }
        }
    }
}
