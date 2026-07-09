import Foundation
import CSQLiteVec

// MARK: - Internal helpers

// Internal (not private) so the actor's public API, split across the
// VectorStore+*.swift extension files, can reach them. Not part of the
// public API surface.
extension VectorStore {
    func validateDimension(of vector: [Float]) throws {
        guard vector.count == dimension else {
            throw SQLiteError.dimensionMismatch(expected: dimension, got: vector.count)
        }
    }

    func validateMetadata(_ metadata: String?) throws {
        guard let metadata else { return }
        let byteCount = metadata.utf8.count
        guard byteCount <= metadataByteLimit else {
            throw SQLiteError.metadataTooLarge(limit: metadataByteLimit, got: byteCount)
        }
    }

    /// Runs `body` inside a transaction (COMMIT on success, ROLLBACK on error).
    /// If a transaction is already open — e.g. `insertBatch` calling the
    /// insert path per entry — `body` runs directly inside it instead of
    /// attempting an invalid nested BEGIN.
    func withTransaction<T>(_ body: () throws -> T) throws -> T {
        guard let ptr = handle?.ptr else { throw SQLiteError.databaseNotOpen }
        guard sqlite3_get_autocommit(ptr) != 0 else { return try body() }
        try executeRaw("BEGIN TRANSACTION;")
        do {
            let result = try body()
            try executeRaw("COMMIT;")
            return result
        } catch {
            try? executeRaw("ROLLBACK;")
            throw error
        }
    }

    /// Prepares `sql`, hands (db, statement) to `body`, and always finalizes.
    func withStatement<T>(
        _ sql: String,
        _ body: (_ ptr: OpaquePointer, _ statement: OpaquePointer) throws -> T
    ) throws -> T {
        guard let ptr = handle?.ptr else { throw SQLiteError.databaseNotOpen }
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(ptr, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(code: prepareCode, message: Self.errorMessage(from: ptr))
        }
        defer { sqlite3_finalize(statement) }
        return try body(ptr, statement)
    }

    func insertCore(_ entry: VectorEntry) throws {
        _ = try insertRow(id: entry.id, content: entry.content, source: entry.source,
                          metadata: entry.metadata, vector: entry.vector)
    }

    /// Shared INSERT path. `id == nil` binds NULL so vec0 assigns the next
    /// rowid; the assigned (or given) id is returned. The vec0 row and its
    /// FTS mirror are written atomically.
    @discardableResult
    func insertRow(id: Int?, content: String, source: String, metadata: String?, vector: [Float]) throws -> Int {
        try validateDimension(of: vector)
        try validateMetadata(metadata)

        return try withTransaction {
            let sql = """
                INSERT INTO \(tableName)(id, content, source, metadata, embedding)
                VALUES (?, ?, ?, ?, ?);
            """
            let assignedID = try withStatement(sql) { ptr, statement in
                if let id {
                    sqlite3_bind_int64(statement, 1, Int64(id))
                } else {
                    sqlite3_bind_null(statement, 1)
                }
                sqlite3_bind_text(statement, 2, content, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 3, source, -1, SQLITE_TRANSIENT)
                if let metadata {
                    sqlite3_bind_text(statement, 4, metadata, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                vector.withUnsafeBytes { rawBuffer in
                    _ = sqlite3_bind_blob(statement, 5, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
                }
                let stepCode = sqlite3_step(statement)
                guard stepCode == SQLITE_DONE else {
                    throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
                }
                return id ?? Int(sqlite3_last_insert_rowid(ptr))
            }

            if lexicalSearch {
                try withStatement("INSERT INTO \(ftsTableName)(rowid, content) VALUES (?, ?);") { ptr, statement in
                    sqlite3_bind_int64(statement, 1, Int64(assignedID))
                    sqlite3_bind_text(statement, 2, content, -1, SQLITE_TRANSIENT)
                    let stepCode = sqlite3_step(statement)
                    guard stepCode == SQLITE_DONE else {
                        throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
                    }
                }
            }
            return assignedID
        }
    }

    // Internal no-bindings variant (kept separate from the public
    // execute(_:bindings:) so internal call sites stay unambiguous).
    func executeRaw(_ sql: String) throws {
        guard let ptr = handle?.ptr else { throw SQLiteError.databaseNotOpen }
        let result = sqlite3_exec(ptr, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.executionFailed(code: result, message: Self.errorMessage(from: ptr))
        }
    }

    // MARK: - Schema (static, callable from the nonisolated init)

    // Table names are interpolated into SQL, so they are restricted to
    // identifier-safe characters (no quoting, no injection surface).
    static func isValidTableName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard (first.isASCII && first.isLetter) || first == "_" else { return false }
        return name.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }
    }

    // `source` is a vec0 metadata column (filterable in KNN queries);
    // `+content` and `+metadata` are auxiliary columns (cheap storage for long
    // text, but they cannot appear in a KNN WHERE clause).
    static func createTableSQL(
        tableName: String,
        dimension: Int,
        distanceMetric: DistanceMetric
    ) -> String {
        """
            CREATE VIRTUAL TABLE IF NOT EXISTS \(tableName) USING vec0(
                id INTEGER PRIMARY KEY,
                embedding FLOAT[\(dimension)] distance_metric=\(distanceMetric.rawValue),
                source TEXT,
                +content TEXT,
                +metadata TEXT
            );
        """
    }

    // Companion full-text index for lexical/hybrid search. Its rowid always
    // equals the vec0 table's id; the actor mirrors every write into it
    // (triggers are not allowed on virtual tables).
    static func ftsTableName(for tableName: String) -> String {
        tableName + "_fts"
    }

    static func createFTSTableSQL(tableName: String) -> String {
        "CREATE VIRTUAL TABLE IF NOT EXISTS \(ftsTableName(for: tableName)) USING fts5(content);"
    }

    // Comparison is deterministic because the v2 DDL is always machine-generated
    // by createTableSQL; hand-tweaked DDL in an existing DB will (correctly)
    // report a mismatch.
    static func normalizedDDL(_ sql: String) -> String {
        var s = sql.lowercased()
        s = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        s = s.replacingOccurrences(of: "if not exists ", with: "")
        s = s.replacingOccurrences(of: ";", with: "")
        for (pattern, replacement) in [(" (", "("), ("( ", "("), (" )", ")"), (", ", ","), (" ,", ",")] {
            s = s.replacingOccurrences(of: pattern, with: replacement)
        }
        return s
    }

    static func existingTableDDL(ptr: OpaquePointer, tableName: String) throws -> String? {
        let sql = "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;"
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(ptr, sql, -1, &statement, nil)
        guard prepareCode == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(code: prepareCode, message: errorMessage(from: ptr))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, tableName, -1, SQLITE_TRANSIENT)

        let stepCode = sqlite3_step(statement)
        if stepCode == SQLITE_ROW {
            return string(from: sqlite3_column_text(statement, 0))
        }
        guard stepCode == SQLITE_DONE else {
            throw SQLiteError.stepFailed(code: stepCode, message: errorMessage(from: ptr))
        }
        return nil
    }

    // Static so it can be called from the nonisolated actor init.
    // CREATE VIRTUAL TABLE IF NOT EXISTS would silently keep an existing table
    // with a *different* schema, so an explicit DDL comparison is mandatory.
    // The lexicalSearch flag is part of the frozen configuration: with it ON
    // the vec0 table and its FTS companion are created/validated as a pair
    // (only one of the two present is rejected — silently adding an empty FTS
    // index next to populated vec0 rows would leave lexical search missing
    // those rows); with it OFF an existing FTS table is likewise rejected
    // rather than silently stranded.
    static func setUpSchema(
        ptr: OpaquePointer,
        dimension: Int,
        distanceMetric: DistanceMetric,
        tableName: String,
        lexicalSearch: Bool
    ) throws {
        let expectedVec = createTableSQL(
            tableName: tableName,
            dimension: dimension,
            distanceMetric: distanceMetric
        )
        let expectedFTS = createFTSTableSQL(tableName: tableName)
        let existingVec = try existingTableDDL(ptr: ptr, tableName: tableName)
        let existingFTS = try existingTableDDL(ptr: ptr, tableName: ftsTableName(for: tableName))

        func create(_ ddl: String) throws {
            let result = sqlite3_exec(ptr, ddl, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw SQLiteError.executionFailed(code: result, message: errorMessage(from: ptr))
            }
        }

        guard lexicalSearch else {
            if let fts = existingFTS {
                throw SQLiteError.schemaMismatch(
                    expected: "no \(ftsTableName(for: tableName)) table (lexicalSearch: false)",
                    found: fts
                )
            }
            if let vec = existingVec {
                guard normalizedDDL(vec) == normalizedDDL(expectedVec) else {
                    throw SQLiteError.schemaMismatch(expected: expectedVec, found: vec)
                }
                return
            }
            try create(expectedVec)
            return
        }

        switch (existingVec, existingFTS) {
        case (nil, nil):
            try create(expectedVec)
            try create(expectedFTS)
        case let (vec?, fts?):
            guard normalizedDDL(vec) == normalizedDDL(expectedVec) else {
                throw SQLiteError.schemaMismatch(expected: expectedVec, found: vec)
            }
            guard normalizedDDL(fts) == normalizedDDL(expectedFTS) else {
                throw SQLiteError.schemaMismatch(expected: expectedFTS, found: fts)
            }
        case let (vec, fts):
            throw SQLiteError.schemaMismatch(
                expected: expectedVec + "\n" + expectedFTS,
                found: vec ?? fts ?? ""
            )
        }
    }

    // MARK: - Statement plumbing (static)

    /// Binds SQL values to consecutive `?` placeholders; returns the next free index.
    @discardableResult
    static func bind(_ values: [SQLValue], to statement: OpaquePointer, startingAt index: Int32) -> Int32 {
        var index = index
        for value in values {
            switch value {
            case .int(let int):
                sqlite3_bind_int64(statement, index, Int64(int))
            case .double(let double):
                sqlite3_bind_double(statement, index, double)
            case .text(let text):
                sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                data.withUnsafeBytes { rawBuffer in
                    _ = sqlite3_bind_blob(statement, index, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
            index += 1
        }
        return index
    }

    /// Reads the column at `column` of the current row as an `SQLValue`.
    static func columnValue(_ statement: OpaquePointer, _ column: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .int(Int(sqlite3_column_int64(statement, column)))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(string(from: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            let byteCount = Int(sqlite3_column_bytes(statement, column))
            guard byteCount > 0, let blob = sqlite3_column_blob(statement, column) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: blob, count: byteCount))
        default:
            return .null
        }
    }

    /// Steps through a query whose columns are (id, content, source, metadata,
    /// distance-or-score) and collects the rows.
    static func collectResults(ptr: OpaquePointer, statement: OpaquePointer) throws -> [SearchResult] {
        var results: [SearchResult] = []
        while true {
            let stepCode = sqlite3_step(statement)
            if stepCode == SQLITE_DONE { break }
            guard stepCode == SQLITE_ROW else {
                throw SQLiteError.stepFailed(code: stepCode, message: errorMessage(from: ptr))
            }
            results.append(SearchResult(
                id: Int(sqlite3_column_int64(statement, 0)),
                content: string(from: sqlite3_column_text(statement, 1)),
                source: string(from: sqlite3_column_text(statement, 2)),
                metadata: optionalString(from: sqlite3_column_text(statement, 3)),
                distance: sqlite3_column_double(statement, 4)
            ))
        }
        return results
    }

    static func errorMessage(from ptr: OpaquePointer?) -> String? {
        guard let ptr, let cString = sqlite3_errmsg(ptr) else { return nil }
        return String(cString: cString)
    }

    static func string(from text: UnsafePointer<UInt8>?) -> String {
        guard let text else { return "" }
        return String(cString: text)
    }

    // For nullable columns: NULL maps to nil (string(from:) coerces it to "").
    static func optionalString(from text: UnsafePointer<UInt8>?) -> String? {
        guard let text else { return nil }
        return String(cString: text)
    }
}

// Internal (not private) because the Search and Mutations extension files
// bind text/blobs directly. https://sqlite.org/c3ref/c_static.html
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
