import Foundation

// MARK: - SQLValue

/// A SQLite value, used both to bind query parameters and to read columns.
public enum SQLValue: Sendable, Equatable {
    /// Signed integer value.
    case int(Int)

    /// Double-precision floating-point value.
    case double(Double)

    /// UTF-8 text value.
    case text(String)

    /// Raw blob value.
    case blob(Data)

    /// SQL `NULL`.
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

    /// Returns the raw SQLite value for a column name, or `nil` when absent.
    public subscript(_ column: String) -> SQLValue? {
        values[column]
    }

    /// Returns the integer value for `column`, or `nil` if absent or not an integer.
    public func int(_ column: String) -> Int? {
        guard case .int(let value)? = values[column] else { return nil }
        return value
    }

    /// Returns the floating-point value for `column`.
    /// Integer values are widened to `Double`; other types return `nil`.
    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .double(let value)?: return value
        case .int(let value)?: return Double(value)
        default: return nil
        }
    }

    /// Returns the text value for `column`, or `nil` if absent or not text.
    public func text(_ column: String) -> String? {
        guard case .text(let value)? = values[column] else { return nil }
        return value
    }

    /// Returns the blob value for `column`, or `nil` if absent or not a blob.
    public func blob(_ column: String) -> Data? {
        guard case .blob(let value)? = values[column] else { return nil }
        return value
    }
}
