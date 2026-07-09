import Foundation

/// Every error thrown by `VectorStore`. Conforms to `LocalizedError`, so
/// `localizedDescription` includes the SQLite error code and detail message
/// where applicable.
public enum SQLiteError: Sendable, LocalizedError {
    case databaseOpenFailed(code: Int32, message: String?)
    case databaseNotOpen
    case registrationFailed(code: Int32, message: String?)
    case executionFailed(code: Int32, message: String?)
    case prepareFailed(code: Int32, message: String?)
    case stepFailed(code: Int32, message: String?)
    case invalidTableName(String)
    case invalidDimension(Int)
    case schemaMismatch(expected: String, found: String)
    case dimensionMismatch(expected: Int, got: Int)
    case metadataTooLarge(limit: Int, got: Int)
    case invalidTopK(Int)
    case rowNotFound(id: Int)
    case invalidTextQuery(String, detail: String?)
    case lexicalSearchDisabled

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
