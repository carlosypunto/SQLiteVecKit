// MARK: - Insert

extension VectorStore {
    /// Inserts one entry. Throws if `entry.id` already exists, if the vector
    /// length differs from the store dimension, or if metadata exceeds the
    /// byte limit.
    public func insert(_ entry: VectorEntry) throws {
        try insertCore(entry)
    }

    /// Labeled convenience for ``insert(_:)`` without building a `VectorEntry`.
    public func insert(id: Int, content: String, source: String, metadata: String? = nil, vector: [Float]) throws {
        try insertCore(VectorEntry(id: id, content: content, source: source, metadata: metadata, vector: vector))
    }

    /// `[Double]` convenience; converted to `[Float]` (sqlite-vec stores float32).
    /// Disfavored so numeric-literal arrays keep resolving to the [Float] overload.
    @_disfavoredOverload
    public func insert(id: Int, content: String, source: String, metadata: String? = nil, vector: [Double]) throws {
        try insertCore(VectorEntry(id: id, content: content, source: source, metadata: metadata, vector: vector))
    }

    /// Inserts a row letting SQLite assign the next available id.
    /// Returns the assigned id.
    @discardableResult
    public func insert(content: String, source: String, metadata: String? = nil, vector: [Float]) throws -> Int {
        try insertRow(id: nil, content: content, source: source, metadata: metadata, vector: vector)
    }

    /// `[Double]` convenience; converted to `[Float]` (sqlite-vec stores float32).
    @discardableResult
    @_disfavoredOverload
    public func insert(content: String, source: String, metadata: String? = nil, vector: [Double]) throws -> Int {
        try insertRow(id: nil, content: content, source: source, metadata: metadata, vector: vector.map(Float.init))
    }

    /// Inserts all entries inside a single transaction — much faster than
    /// row-by-row inserts, and all-or-nothing: entries are pre-validated
    /// (dimension and metadata size) before any write, and any mid-batch
    /// failure rolls the whole batch back.
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
