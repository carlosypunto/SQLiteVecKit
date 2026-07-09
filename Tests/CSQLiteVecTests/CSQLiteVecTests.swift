import Testing
import Foundation
import CSQLiteVec

// MARK: - Raw sqlite3 helpers

// https://sqlite.org/c3ref/c_static.html
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Opens an in-memory database, registers sqlite-vec, runs `body`, and closes.
private func withRawDB(_ body: (OpaquePointer) throws -> Void) throws {
    var db: OpaquePointer?
    #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
    guard let db else { return }
    defer { sqlite3_close(db) }
    #expect(sqlite_vec_bootstrap(db) == SQLITE_OK)
    try body(db)
}

private func exec(_ db: OpaquePointer, _ sql: String) -> Int32 {
    sqlite3_exec(db, sql, nil, nil, nil)
}

private func bindBlob(_ stmt: OpaquePointer, _ index: Int32, _ vector: [Float]) {
    vector.withUnsafeBytes { raw in
        _ = sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
    }
}

/// Prepares `sql`, binds the given float blobs in order, and returns the first
/// column of the first row as Double, or nil if prepare/step fails.
private func scalarDouble(_ db: OpaquePointer, _ sql: String, blobs: [[Float]]) -> Double? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    for (i, blob) in blobs.enumerated() {
        bindBlob(stmt, Int32(i + 1), blob)
    }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return sqlite3_column_double(stmt, 0)
}

/// Deterministic pseudo-random vector generator (splitmix64-based).
private func randomVector(dimension: Int, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<dimension).map { _ in
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        // Map to [-1, 1]
        return Float(Double(z) / Double(UInt64.max)) * 2 - 1
    }
}

// MARK: - Bootstrap

@Suite("C.Bootstrap")
struct BootstrapTests {
    @Test func bootstrapSucceedsOnFreshConnection() throws {
        try withRawDB { _ in }
    }

    @Test func bootstrapWorksOnMultipleConnections() throws {
        try withRawDB { _ in
            try withRawDB { _ in }
        }
    }
}

// MARK: - Version

@Suite("C.Version")
struct VersionTests {
    @Test func bundledVersionMatchesHeader() {
        #expect(String(cString: sqlite_vec_bundled_version()) == "v0.1.9")
    }

    @Test func sqlVecVersionMatchesCVersion() throws {
        try withRawDB { db in
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT vec_version();", -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            #expect(sqlite3_step(stmt) == SQLITE_ROW)
            let sqlVersion = String(cString: sqlite3_column_text(stmt!, 0))
            #expect(sqlVersion == String(cString: sqlite_vec_bundled_version()))
        }
    }
}

// MARK: - vec0 raw behavior

@Suite("C.Vec0Raw")
struct Vec0RawTests {
    @Test func createInsertKnnRoundTrip() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE t USING vec0(embedding FLOAT[4]);") == SQLITE_OK)

            let vectors: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0.9, 0.1, 0, 0]]
            for (i, v) in vectors.enumerated() {
                var stmt: OpaquePointer?
                #expect(sqlite3_prepare_v2(db, "INSERT INTO t(rowid, embedding) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, Int64(i + 1))
                bindBlob(stmt!, 2, v)
                #expect(sqlite3_step(stmt) == SQLITE_DONE)
            }

            var stmt: OpaquePointer?
            let sql = "SELECT rowid, distance FROM t WHERE embedding MATCH ? AND k = 2 ORDER BY distance;"
            #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            bindBlob(stmt!, 1, [1, 0, 0, 0])

            var rows: [(id: Int64, distance: Double)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1)))
            }
            #expect(rows.count == 2)
            #expect(rows[0].id == 1)          // exact match first
            #expect(rows[0].distance == 0.0)
            #expect(rows[1].id == 3)          // then the near vector
        }
    }

    @Test func metadataColumnFiltersInKnn() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE t USING vec0(embedding FLOAT[3], source TEXT);") == SQLITE_OK)
            let rows: [(Int64, String, [Float])] = [
                (1, "a", [1, 0, 0]), (2, "b", [0.9, 0.1, 0]), (3, "a", [0, 1, 0]),
            ]
            for (id, source, v) in rows {
                var stmt: OpaquePointer?
                #expect(sqlite3_prepare_v2(db, "INSERT INTO t(rowid, embedding, source) VALUES (?, ?, ?);", -1, &stmt, nil) == SQLITE_OK)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, id)
                bindBlob(stmt!, 2, v)
                sqlite3_bind_text(stmt, 3, source, -1, SQLITE_TRANSIENT)
                #expect(sqlite3_step(stmt) == SQLITE_DONE)
            }

            var stmt: OpaquePointer?
            let sql = "SELECT rowid FROM t WHERE embedding MATCH ? AND k = 5 AND source = 'a' ORDER BY distance;"
            #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            bindBlob(stmt!, 1, [1, 0, 0])

            var ids: [Int64] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(sqlite3_column_int64(stmt, 0))
            }
            #expect(ids == [1, 3])  // only source 'a', closest first
        }
    }

    @Test func auxiliaryColumnRejectedInKnnWhere() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE t USING vec0(embedding FLOAT[3], +content TEXT);") == SQLITE_OK)
            var stmt: OpaquePointer?
            let sql = "SELECT rowid FROM t WHERE embedding MATCH ? AND k = 1 AND content = 'x';"
            let prepareCode = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            var failed = prepareCode != SQLITE_OK
            if !failed, let stmt {
                bindBlob(stmt, 1, [1, 0, 0])
                let stepCode = sqlite3_step(stmt)
                failed = stepCode != SQLITE_ROW && stepCode != SQLITE_DONE
            }
            // Documents the vec0 constraint: aux columns cannot appear in a KNN WHERE.
            #expect(failed)
        }
    }

    @Test func cosineMetricAccepted() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE t USING vec0(embedding FLOAT[3] distance_metric=cosine);") == SQLITE_OK)
            for (id, v) in [(1, [Float]([1, 0, 0])), (2, [-1, 0, 0]), (3, [1, 0, 0])] {
                var stmt: OpaquePointer?
                #expect(sqlite3_prepare_v2(db, "INSERT INTO t(rowid, embedding) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, Int64(id))
                bindBlob(stmt!, 2, v)
                #expect(sqlite3_step(stmt) == SQLITE_DONE)
            }

            var stmt: OpaquePointer?
            let sql = "SELECT rowid, distance FROM t WHERE embedding MATCH ? AND k = 3 ORDER BY distance;"
            #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            bindBlob(stmt!, 1, [1, 0, 0])

            var distances: [Double] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                distances.append(sqlite3_column_double(stmt, 1))
            }
            #expect(distances.count == 3)
            #expect(abs(distances[0] - 0.0) < 1e-6)  // identical direction
            #expect(abs(distances[1] - 0.0) < 1e-6)
            #expect(abs(distances[2] - 2.0) < 1e-6)  // opposite direction
        }
    }

    @Test func l2MetricAccepted() throws {
        try withRawDB { db in
            // Risk check for the Swift wrapper's machine-generated DDL: explicit l2 must be valid.
            #expect(exec(db, "CREATE VIRTUAL TABLE t USING vec0(embedding FLOAT[3] distance_metric=l2);") == SQLITE_OK)
        }
    }

    @Test func wrongDimensionBlobFailsAtSQLiteLevel() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE t USING vec0(embedding FLOAT[4]);") == SQLITE_OK)
            var stmt: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "INSERT INTO t(rowid, embedding) VALUES (1, ?);", -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            bindBlob(stmt!, 1, [1, 0, 0])  // 3 floats into FLOAT[4]
            #expect(sqlite3_step(stmt) != SQLITE_DONE)
        }
    }
}

// MARK: - System SQLite capabilities

// The Swift wrapper's lexical search (FTS5 + bm25), JSON metadata filtering
// (JSON1), and auto-assigned ids (NULL INTEGER PRIMARY KEY on vec0) all depend
// on capabilities of Apple's system libsqlite3 or of vec0 itself. These tests
// turn those assumptions into hard guarantees and act as OS/vendor-upgrade canaries.
@Suite("C.SystemCapabilities")
struct SystemCapabilityTests {
    @Test func fts5WithBM25IsAvailable() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE f USING fts5(content);") == SQLITE_OK)
            #expect(exec(db, "INSERT INTO f(rowid, content) VALUES (1, 'swift vector search');") == SQLITE_OK)
            #expect(exec(db, "INSERT INTO f(rowid, content) VALUES (2, 'lexical keyword match');") == SQLITE_OK)

            var stmt: OpaquePointer?
            let sql = "SELECT rowid, bm25(f) FROM f WHERE f MATCH 'keyword' ORDER BY bm25(f);"
            #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            #expect(sqlite3_step(stmt) == SQLITE_ROW)
            #expect(sqlite3_column_int64(stmt, 0) == 2)
            #expect(sqlite3_column_double(stmt, 1) < 0)  // bm25() is negative; lower = better
            #expect(sqlite3_step(stmt) == SQLITE_DONE)   // only one match
        }
    }

    @Test func fts5DeleteAndUpdateByRowidWork() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE f USING fts5(content);") == SQLITE_OK)
            #expect(exec(db, "INSERT INTO f(rowid, content) VALUES (1, 'old text');") == SQLITE_OK)
            #expect(exec(db, "UPDATE f SET content = 'new text' WHERE rowid = 1;") == SQLITE_OK)
            #expect(exec(db, "DELETE FROM f WHERE rowid = 1;") == SQLITE_OK)
        }
    }

    @Test func json1ExtractIsAvailable() throws {
        try withRawDB { db in
            var stmt: OpaquePointer?
            let sql = "SELECT json_extract(?, ?);"
            #expect(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, #"{"page": 7, "tag": "bio"}"#, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, "$.page", -1, SQLITE_TRANSIENT)
            #expect(sqlite3_step(stmt) == SQLITE_ROW)
            #expect(sqlite3_column_int64(stmt, 0) == 7)
        }
    }

    @Test func vec0AssignsRowidWhenIdIsNull() throws {
        try withRawDB { db in
            #expect(exec(db, "CREATE VIRTUAL TABLE t USING vec0(id INTEGER PRIMARY KEY, embedding FLOAT[3]);") == SQLITE_OK)

            func insertWithNullId(_ v: [Float]) -> Int64? {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO t(id, embedding) VALUES (NULL, ?);", -1, &stmt, nil) == SQLITE_OK else { return nil }
                defer { sqlite3_finalize(stmt) }
                bindBlob(stmt!, 1, v)
                guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
                return sqlite3_last_insert_rowid(db)
            }

            let first = insertWithNullId([1, 0, 0])
            let second = insertWithNullId([0, 1, 0])
            #expect(first != nil && second != nil)
            if let first, let second {
                #expect(second > first)  // monotonically assigned
            }
        }
    }
}

// MARK: - SIMD consistency

// On arm64 the NEON fast path is enabled via SQLiteVecShim.c; the float L2 path
// triggers for dimension > 16. Comparing against a scalar Swift reference across
// dimensions on both sides of that threshold proves the NEON and scalar paths agree.
@Suite("C.Simd")
struct SimdTests {
    private let dimensions = [3, 8, 16, 17, 32, 128, 512]

    private func relativeError(_ got: Double, _ expected: Double) -> Double {
        abs(got - expected) / max(1.0, abs(expected))
    }

    @Test func neonAndScalarL2Agree() throws {
        try withRawDB { db in
            for dim in dimensions {
                let a = randomVector(dimension: dim, seed: UInt64(dim))
                let b = randomVector(dimension: dim, seed: UInt64(dim) &+ 999)

                let reference = sqrt(zip(a, b).reduce(0.0) { acc, pair in
                    let d = Double(pair.0) - Double(pair.1)
                    return acc + d * d
                })
                let got = scalarDouble(db, "SELECT vec_distance_l2(?, ?);", blobs: [a, b])
                #expect(got != nil, "vec_distance_l2 failed for dim \(dim)")
                if let got {
                    #expect(relativeError(got, reference) < 1e-4, "L2 mismatch at dim \(dim): \(got) vs \(reference)")
                }
            }
        }
    }

    @Test func neonAndScalarCosineAgree() throws {
        try withRawDB { db in
            for dim in dimensions {
                let a = randomVector(dimension: dim, seed: UInt64(dim) &+ 1)
                let b = randomVector(dimension: dim, seed: UInt64(dim) &+ 1000)

                var dot = 0.0, na = 0.0, nb = 0.0
                for (x, y) in zip(a, b) {
                    dot += Double(x) * Double(y)
                    na += Double(x) * Double(x)
                    nb += Double(y) * Double(y)
                }
                let reference = 1.0 - dot / (sqrt(na) * sqrt(nb))
                let got = scalarDouble(db, "SELECT vec_distance_cosine(?, ?);", blobs: [a, b])
                #expect(got != nil, "vec_distance_cosine failed for dim \(dim)")
                if let got {
                    #expect(relativeError(got, reference) < 1e-4, "cosine mismatch at dim \(dim): \(got) vs \(reference)")
                }
            }
        }
    }
}
