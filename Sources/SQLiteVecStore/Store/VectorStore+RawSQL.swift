import CSQLiteVec

// MARK: - Raw SQL access

extension VectorStore {
    /// Runs an arbitrary SELECT (or any row-returning statement) on the
    /// store's connection and collects the rows. The connection has sqlite-vec
    /// loaded, so this can query the store's vec0 table, your own tables in
    /// the same database, or joins between them.
    ///
    /// Conventions (see DECISIONS.md #6): treat the store's vec0 table as
    /// read-only from SQL; never touch the internal `<table>_fts` index; use
    /// `?` placeholders with `bindings` for every value.
    ///
    /// - Parameters:
    ///   - sql: SQL statement to prepare and step. Usually a `SELECT`.
    ///   - bindings: Values bound to consecutive `?` placeholders.
    /// - Returns: Rows keyed by column name, preserving SELECT column order in
    ///   ``SQLRow/columnNames``.
    /// - Throws: ``SQLiteError/prepareFailed(code:message:)`` or
    ///   ``SQLiteError/stepFailed(code:message:)`` when SQLite rejects the statement.
    public func query(_ sql: String, bindings: [SQLValue] = []) throws -> [SQLRow] {
        try withStatement(sql) { ptr, statement in
            Self.bind(bindings, to: statement, startingAt: 1)
            let columnCount = sqlite3_column_count(statement)
            let columnNames = (0..<columnCount).map { column in
                sqlite3_column_name(statement, column).map { String(cString: $0) } ?? "column\(column)"
            }
            var rows: [SQLRow] = []
            while true {
                let stepCode = sqlite3_step(statement)
                if stepCode == SQLITE_DONE { break }
                guard stepCode == SQLITE_ROW else {
                    throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
                }
                var values: [String: SQLValue] = [:]
                for column in 0..<columnCount {
                    values[columnNames[Int(column)]] = Self.columnValue(statement, column)
                }
                rows.append(SQLRow(columnNames: columnNames, values: values))
            }
            return rows
        }
    }

    /// Runs an arbitrary non-SELECT statement (DDL/DML) on the store's
    /// connection; returns the number of rows changed. Intended for managing
    /// your own tables alongside the store — writes to the store's own tables
    /// must go through the typed API (raw writes bypass the FTS sync and
    /// validations). See `query(_:bindings:)` for the full conventions.
    ///
    /// - Parameters:
    ///   - sql: Non-SELECT SQL statement to prepare and execute.
    ///   - bindings: Values bound to consecutive `?` placeholders.
    /// - Returns: The current `sqlite3_changes` count after execution.
    /// - Throws: ``SQLiteError/prepareFailed(code:message:)`` or
    ///   ``SQLiteError/stepFailed(code:message:)`` when SQLite rejects the statement.
    @discardableResult
    public func execute(_ sql: String, bindings: [SQLValue] = []) throws -> Int {
        try withStatement(sql) { ptr, statement in
            Self.bind(bindings, to: statement, startingAt: 1)
            let stepCode = sqlite3_step(statement)
            guard stepCode == SQLITE_DONE || stepCode == SQLITE_ROW else {
                throw SQLiteError.stepFailed(code: stepCode, message: Self.errorMessage(from: ptr))
            }
            return Int(sqlite3_changes(ptr))
        }
    }
}
