// MARK: - Insert

extension VectorStore {
    /// Inserts one entry. Throws if `entry.id` already exists, if the vector
    /// length differs from the store dimension, or if metadata exceeds the
    /// byte limit.
    ///
    /// - Parameter entry: Fully specified row to insert.
    /// - Throws: ``SQLiteError/dimensionMismatch(expected:got:)``,
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``, or a SQLite constraint
    ///   error if the id already exists.
    public func insert(_ entry: VectorEntry) throws {
        try insertCore(entry)
    }

    /// Labeled convenience for ``insert(_:)`` without building a `VectorEntry`.
    ///
    /// - Parameters:
    ///   - id: Stable unique row identifier.
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Raw metadata string, usually compact JSON, or `nil`.
    ///   - vector: Embedding vector. Its count must match the store dimension.
    /// - Throws: ``SQLiteError/dimensionMismatch(expected:got:)``,
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``, or a SQLite constraint
    ///   error if the id already exists.
    public func insert(id: Int, content: String, source: String, metadata: String? = nil, vector: [Float]) throws {
        try insertCore(VectorEntry(id: id, content: content, source: source, metadata: metadata, vector: vector))
    }

    /// `[Double]` convenience; converted to `[Float]` (sqlite-vec stores float32).
    /// Disfavored so numeric-literal arrays keep resolving to the [Float] overload.
    ///
    /// - Parameters:
    ///   - id: Stable unique row identifier.
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Raw metadata string, usually compact JSON, or `nil`.
    ///   - vector: Embedding vector converted with `Float.init`.
    /// - Throws: ``SQLiteError/dimensionMismatch(expected:got:)``,
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``, or a SQLite constraint
    ///   error if the id already exists.
    @_disfavoredOverload
    public func insert(id: Int, content: String, source: String, metadata: String? = nil, vector: [Double]) throws {
        try insertCore(VectorEntry(id: id, content: content, source: source, metadata: metadata, vector: vector))
    }

    /// Inserts a row letting SQLite assign the next available id.
    /// Returns the assigned id.
    ///
    /// - Parameters:
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Raw metadata string, usually compact JSON, or `nil`.
    ///   - vector: Embedding vector. Its count must match the store dimension.
    /// - Returns: SQLite-assigned row id.
    /// - Throws: ``SQLiteError/dimensionMismatch(expected:got:)`` or
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``.
    @discardableResult
    public func insert(content: String, source: String, metadata: String? = nil, vector: [Float]) throws -> Int {
        try insertRow(id: nil, content: content, source: source, metadata: metadata, vector: vector)
    }

    /// `[Double]` convenience; converted to `[Float]` (sqlite-vec stores float32).
    ///
    /// - Parameters:
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Raw metadata string, usually compact JSON, or `nil`.
    ///   - vector: Embedding vector converted with `Float.init`.
    /// - Returns: SQLite-assigned row id.
    /// - Throws: ``SQLiteError/dimensionMismatch(expected:got:)`` or
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``.
    @discardableResult
    @_disfavoredOverload
    public func insert(content: String, source: String, metadata: String? = nil, vector: [Double]) throws -> Int {
        try insertRow(id: nil, content: content, source: source, metadata: metadata, vector: vector.map(Float.init))
    }

    /// Inserts all entries inside a single transaction — much faster than
    /// row-by-row inserts, and all-or-nothing: entries are pre-validated
    /// (dimension and metadata size) before any write, and any mid-batch
    /// failure rolls the whole batch back.
    ///
    /// - Parameter entries: Entries to insert. An empty array is a no-op.
    /// - Throws: ``SQLiteError/dimensionMismatch(expected:got:)``,
    ///   ``SQLiteError/metadataTooLarge(limit:got:)``, or any SQLite write
    ///   error such as a duplicate primary key.
    public func insertBatch(_ entries: [VectorEntry]) throws {
        guard !entries.isEmpty else { return }
        // Pre-scan so a bad entry fails with a clean error before any write.
        for entry in entries {
            try validateDimension(of: entry.vector)
            try validateMetadata(entry.metadata)
        }
        try withTransaction {
            for entry in entries {
                try insertCore(entry)
            }
        }
    }
}
