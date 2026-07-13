import Foundation
import CSQLiteVec

// MARK: - Fetch, update, upsert, delete, count

extension VectorStore {
    /// Reads a full row back, including the stored embedding.
    /// Returns nil if no row with the given id exists.
    ///
    /// - Parameter id: Row identifier to fetch.
    /// - Returns: The stored entry, or `nil` when no row has that id.
    /// - Throws: ``SQLiteError`` if the underlying query fails.
    public func fetch(id: Int) throws -> VectorEntry? {
        let sql = "SELECT content, source, metadata, embedding FROM \(tableName) WHERE id = ?;"
        return try withStatement(sql) { ptr, statement in
            sqlite3_bind_int64(statement, 1, Int64(id))
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let content = Self.string(from: sqlite3_column_text(statement, 0))
                let source = Self.string(from: sqlite3_column_text(statement, 1))
                let metadata = Self.optionalString(from: sqlite3_column_text(statement, 2))
                let byteCount = Int(sqlite3_column_bytes(statement, 3))
                guard byteCount == dimension * MemoryLayout<Float>.size,
                      let blob = sqlite3_column_blob(statement, 3) else {
                    // Schema checks make this unreachable in practice; report it as
                    // a dimension problem rather than crashing.
                    throw SQLiteError.dimensionMismatch(
                        expected: dimension,
                        got: byteCount / MemoryLayout<Float>.size
                    )
                }
                let vector = [Float](unsafeUninitializedCapacity: dimension) { buffer, count in
                    memcpy(buffer.baseAddress!, blob, byteCount)
                    count = dimension
                }
                return VectorEntry(id: id, content: content, source: source, metadata: metadata, vector: vector)
            case SQLITE_DONE:
                return nil
            case let stepCode:
                throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
            }
        }
    }

    /// Replaces content, source, metadata, and embedding of an existing row.
    /// Throws `SQLiteError.rowNotFound` if the id does not exist.
    ///
    /// - Parameter entry: Replacement row. Its `id` selects the row to update.
    /// - Throws: ``SQLiteError/rowNotFound(id:)`` when the id is missing,
    ///   ``SQLiteError/dimensionMismatch(expected:got:)``,
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``, or a SQLite write error.
    public func update(_ entry: VectorEntry) throws {
        try validateDimension(of: entry.vector)
        try validateMetadata(entry.metadata)
        // Existence is checked explicitly rather than via sqlite3_changes(),
        // whose reporting for virtual tables is not guaranteed.
        guard try contains(id: entry.id) else { throw SQLiteError.rowNotFound(id: entry.id) }

        try withTransaction {
            let sql = "UPDATE \(tableName) SET content = ?, source = ?, metadata = ?, embedding = ? WHERE id = ?;"
            try withStatement(sql) { ptr, statement in
                sqlite3_bind_text(statement, 1, entry.content, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, entry.source, -1, SQLITE_TRANSIENT)
                if let metadata = entry.metadata {
                    sqlite3_bind_text(statement, 3, metadata, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                entry.vector.withUnsafeBytes { rawBuffer in
                    _ = sqlite3_bind_blob(statement, 4, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(statement, 5, Int64(entry.id))
                let stepCode = sqlite3_step(statement)
                guard stepCode == SQLITE_DONE else {
                    throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
                }
            }

            if lexicalSearch {
                try withStatement("UPDATE \(ftsTableName) SET content = ? WHERE rowid = ?;") { ptr, statement in
                    sqlite3_bind_text(statement, 1, entry.content, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(statement, 2, Int64(entry.id))
                    let stepCode = sqlite3_step(statement)
                    guard stepCode == SQLITE_DONE else {
                        throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
                    }
                }
            }
        }
    }

    /// Inserts the entry, replacing any existing row with the same id.
    /// Implemented as DELETE + INSERT in one transaction because
    /// `INSERT OR REPLACE` is broken on vec0 tables (upstream issue #259).
    ///
    /// - Parameter entry: Row to insert or replace.
    /// - Throws: ``SQLiteError/dimensionMismatch(expected:got:)``,
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``, or a SQLite write error.
    public func upsert(_ entry: VectorEntry) throws {
        try validateDimension(of: entry.vector)
        try validateMetadata(entry.metadata)
        try withTransaction {
            try delete(id: entry.id)
            try insertCore(entry)
        }
    }

    /// Deletes the row with the given id. Deleting a nonexistent id is a no-op.
    ///
    /// - Parameter id: Row identifier to delete.
    /// - Throws: ``SQLiteError`` if the underlying delete fails.
    public func delete(id: Int) throws {
        var statements = ["DELETE FROM \(tableName) WHERE id = ?;"]
        if lexicalSearch {
            statements.append("DELETE FROM \(ftsTableName) WHERE rowid = ?;")
        }
        try withTransaction {
            for sql in statements {
                try withStatement(sql) { ptr, statement in
                    sqlite3_bind_int64(statement, 1, Int64(id))
                    let stepCode = sqlite3_step(statement)
                    guard stepCode == SQLITE_DONE else {
                        throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
                    }
                }
            }
        }
    }

    /// Deletes every row with the given source (e.g. to re-ingest one document).
    /// Deleting a source with no rows is a no-op.
    ///
    /// - Parameter source: Source label whose rows should be removed.
    /// - Throws: ``SQLiteError`` if the underlying delete fails.
    public func delete(source: String) throws {
        // FTS rows first: the subquery needs the vec0 rows still present.
        var statements: [String] = []
        if lexicalSearch {
            statements.append("""
                DELETE FROM \(ftsTableName)
                WHERE rowid IN (SELECT id FROM \(tableName) WHERE source = ?);
            """)
        }
        statements.append("DELETE FROM \(tableName) WHERE source = ?;")
        try withTransaction {
            for sql in statements {
                try withStatement(sql) { ptr, statement in
                    sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
                    let stepCode = sqlite3_step(statement)
                    guard stepCode == SQLITE_DONE else {
                        throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
                    }
                }
            }
        }
    }

    /// Removes every row from the store.
    ///
    /// - Throws: ``SQLiteError`` if the underlying delete fails.
    public func deleteAll() throws {
        try withTransaction {
            try executeRaw("DELETE FROM \(tableName);")
            if lexicalSearch {
                try executeRaw("DELETE FROM \(ftsTableName);")
            }
        }
    }

    /// Returns true if a row with the given id exists.
    ///
    /// - Parameter id: Row identifier to test.
    /// - Returns: `true` when the row exists; otherwise `false`.
    /// - Throws: ``SQLiteError`` if the underlying query fails.
    public func contains(id: Int) throws -> Bool {
        try withStatement("SELECT 1 FROM \(tableName) WHERE id = ? LIMIT 1;") { ptr, statement in
            sqlite3_bind_int64(statement, 1, Int64(id))
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            case let stepCode:
                throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
            }
        }
    }

    /// Number of rows in the store.
    ///
    /// - Returns: Total row count.
    /// - Throws: ``SQLiteError`` if the underlying query fails.
    public func count() throws -> Int {
        try withStatement("SELECT count(*) FROM \(tableName);") { ptr, statement in
            let stepCode = sqlite3_step(statement)
            guard stepCode == SQLITE_ROW else {
                throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Number of rows with the given source.
    ///
    /// - Parameter source: Source label to count.
    /// - Returns: Number of rows whose source equals `source`.
    /// - Throws: ``SQLiteError`` if the underlying query fails.
    public func count(source: String) throws -> Int {
        try withStatement("SELECT count(*) FROM \(tableName) WHERE source = ?;") { ptr, statement in
            sqlite3_bind_text(statement, 1, source, -1, SQLITE_TRANSIENT)
            let stepCode = sqlite3_step(statement)
            guard stepCode == SQLITE_ROW else {
                throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
}
