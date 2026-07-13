import Foundation

/// Every error thrown by `VectorStore`. Conforms to `LocalizedError`, so
/// `localizedDescription` includes the SQLite error code and detail message
/// where applicable.
public enum SQLiteError: Sendable, LocalizedError {
    /// SQLite could not open the database file.
    /// Check the path, parent directory, file permissions, and available storage.
    case databaseOpenFailed(code: Int32, message: String?)

    /// The actor no longer owns an open SQLite connection.
    /// This indicates an internal lifecycle problem rather than a recoverable user input error.
    case databaseNotOpen

    /// The bundled sqlite-vec extension could not be registered on this connection.
    case registrationFailed(code: Int32, message: String?)

    /// A raw SQL statement failed during direct execution.
    case executionFailed(code: Int32, message: String?)

    /// SQLite could not prepare a SQL statement.
    /// This usually means malformed SQL, an unknown table or column, or a schema mismatch.
    case prepareFailed(code: Int32, message: String?)

    /// SQLite returned an error while stepping a prepared statement.
    /// Constraint violations, malformed FTS5 queries, and virtual-table errors can surface here.
    case stepFailed(code: Int32, message: String?)

    /// The configured vec0 table name is not a valid SQLiteVecKit identifier.
    /// Names must match `[A-Za-z_][A-Za-z0-9_]*`.
    case invalidTableName(String)

    /// The store dimension is less than 1.
    case invalidDimension(Int)

    /// The existing database schema does not match the requested store configuration.
    /// Recreate the database and re-ingest with matching dimension, metric, and table layout.
    case schemaMismatch(expected: String, found: String)

    /// A vector passed to insert, update, or search does not match the store dimension.
    case dimensionMismatch(expected: Int, got: Int)

    /// A metadata string is larger than the store's UTF-8 byte limit.
    case metadataTooLarge(limit: Int, got: Int)

    /// `topK` is outside `1...VectorStore.maxTopK`.
    case invalidTopK(Int)

    /// `update(_:)` was called for an id that does not exist.
    case rowNotFound(id: Int)

    /// The query string passed to `searchText` or `searchHybrid` is not valid FTS5 syntax.
    case invalidTextQuery(String, detail: String?)

    /// Text or hybrid search was requested from a store created with `lexicalSearch: false`.
    case lexicalSearchDisabled

    /// Human-readable error text suitable for logs and diagnostics.
    public var errorDescription: String? {
        switch self {
        case let .databaseOpenFailed(code, message):
            return "Failed to open SQLite (\(code)): \(message ?? "no detail")"
        case .databaseNotOpen:
            return "SQLite database is not open"
        case let .registrationFailed(code, message):
            return "Failed to register sqlite-vec (\(code)): \(message ?? "no detail")"
        case let .executionFailed(code, message):
            return "SQL execution failed (\(code)): \(message ?? "no detail")"
        case let .prepareFailed(code, message):
            return "SQL prepare failed (\(code)): \(message ?? "no detail")"
        case let .stepFailed(code, message):
            return "SQL step failed (\(code)): \(message ?? "no detail")"
        case let .invalidTableName(name):
            return "Invalid table name '\(name)'. Use only ASCII letters, digits, and underscores, not starting with a digit."
        case let .invalidDimension(dimension):
            return "Vector dimension must be at least 1, got \(dimension)."
        case let .schemaMismatch(expected, found):
            return "Existing table schema does not match this configuration (dimension, distance metric, or column layout). The database file must be recreated and re-ingested. Expected: \(expected) Found: \(found)"
        case let .dimensionMismatch(expected, got):
            return "Vector has \(got) elements but the store dimension is \(expected)."
        case let .metadataTooLarge(limit, got):
            return "Metadata is \(got) UTF-8 bytes but the store limit is \(limit)."
        case let .invalidTopK(topK):
            return "topK must be between 1 and \(VectorStore.maxTopK), got \(topK)."
        case let .rowNotFound(id):
            return "No row with id \(id) exists in the store."
        case let .invalidTextQuery(query, detail):
            return "Invalid FTS5 text query '\(query)': \(detail ?? "syntax error")"
        case .lexicalSearchDisabled:
            return "Lexical search is disabled for this store. Create the store with lexicalSearch: true (requires a new database file)."
        }
    }
}
