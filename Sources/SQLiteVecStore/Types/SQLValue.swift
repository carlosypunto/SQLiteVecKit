import Foundation

// MARK: - SQLValue

/// A SQLite value, used both to bind query parameters and to read columns.
public enum SQLValue: Sendable, Equatable {
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

// MARK: - SQLRow

/// One row of a `query` result: column-name access with typed accessors.
/// Accessors return nil when the column is absent or holds a different type
/// (the one pragmatic coercion: `double(_:)` also accepts `.int`).
public struct SQLRow: Sendable, Equatable {
    /// Column names in SELECT order.
    public let columnNames: [String]
    private let values: [String: SQLValue]

    init(columnNames: [String], values: [String: SQLValue]) {
        self.columnNames = columnNames
        self.values = values
    }

    public subscript(_ column: String) -> SQLValue? {
        values[column]
    }

    public func int(_ column: String) -> Int? {
        guard case .int(let value)? = values[column] else { return nil }
        return value
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return nil
        }
    }

    public func text(_ column: String) -> String? {
        guard case .text(let value)? = values[column] else { return nil }
        return value
    }

    public func blob(_ column: String) -> Data? {
        guard case .blob(let value)? = values[column] else { return nil }
        return value
    }
}
