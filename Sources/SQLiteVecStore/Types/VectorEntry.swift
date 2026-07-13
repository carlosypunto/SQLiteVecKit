/// A row to insert into the store: id, text content, source tag,
/// optional metadata (typically a JSON string), and embedding.
/// Codable so stores can be exported/snapshotted as plain data.
public struct VectorEntry: Sendable, Equatable, Codable {
    /// Stable row identifier. It must be unique within the store.
    public let id: Int

    /// Text chunk returned by searches and indexed by lexical search when enabled.
    public let content: String

    /// Caller-owned source label, typically a document id, file path, or collection name.
    /// Use `source:` search parameters for efficient per-source filtering.
    public let source: String

    /// Raw metadata string, usually JSON. `nil` means no metadata.
    /// Size is validated against the store's `metadataByteLimit` at write time.
    public let metadata: String?

    /// Embedding vector stored as sqlite-vec `FLOAT[N]`.
    /// Its element count must match the store dimension on insert/update.
    public let vector: [Float]

    /// Creates an entry with raw metadata stored verbatim.
    ///
    /// - Parameters:
    ///   - id: Stable unique row identifier.
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Raw metadata string, usually compact JSON, or `nil`.
    ///   - vector: Embedding vector. The store validates its dimension at write time.
    public init(id: Int, content: String, source: String, metadata: String? = nil, vector: [Float]) {
        self.id = id
        self.content = content
        self.source = source
        self.metadata = metadata
        self.vector = vector
    }

    /// Encodes `metadata` to a compact JSON string (deterministic key order).
    /// Distinct `encoding:` label so a plain `String` always resolves to the
    /// raw-storage `metadata:` overload instead of being JSON-encoded
    /// (which would add surrounding quotes).
    ///
    /// - Parameters:
    ///   - id: Stable unique row identifier.
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Value to JSON-encode into the raw metadata column.
    ///   - vector: Embedding vector. The store validates its dimension at write time.
    /// - Throws: Any error thrown while JSON-encoding `metadata`.
    public init(id: Int, content: String, source: String, encoding metadata: some Encodable, vector: [Float]) throws {
        try self.init(id: id, content: content, source: source,
                      metadata: MetadataJSON.encode(metadata), vector: vector)
    }

    /// Convenience for embedders that produce `[Double]`; converted to `[Float]`
    /// (the canonical vector type — sqlite-vec stores float32).
    /// Disfavored so numeric-literal arrays keep resolving to the [Float] overload.
    ///
    /// - Parameters:
    ///   - id: Stable unique row identifier.
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Raw metadata string, usually compact JSON, or `nil`.
    ///   - vector: Embedding vector converted with `Float.init`.
    @_disfavoredOverload
    public init(id: Int, content: String, source: String, metadata: String? = nil, vector: [Double]) {
        self.init(id: id, content: content, source: source,
                  metadata: metadata, vector: vector.map(Float.init))
    }

    /// `[Double]` + Codable metadata convenience.
    ///
    /// - Parameters:
    ///   - id: Stable unique row identifier.
    ///   - content: Text chunk to store and return from searches.
    ///   - source: Caller-owned source label, usually a document id or path.
    ///   - metadata: Value to JSON-encode into the raw metadata column.
    ///   - vector: Embedding vector converted with `Float.init`.
    /// - Throws: Any error thrown while JSON-encoding `metadata`.
    @_disfavoredOverload
    public init(id: Int, content: String, source: String, encoding metadata: some Encodable, vector: [Double]) throws {
        try self.init(id: id, content: content, source: source,
                      metadata: MetadataJSON.encode(metadata), vector: vector.map(Float.init))
    }
}
