/// A row to insert into the store: id, text content, source tag,
/// optional metadata (typically a JSON string), and embedding.
/// Codable so stores can be exported/snapshotted as plain data.
public struct VectorEntry: Sendable, Equatable, Codable {
    public let id: Int
    public let content: String
    public let source: String
    /// Raw metadata string, usually JSON. `nil` means no metadata.
    /// Size is validated against the store's `metadataByteLimit` at write time.
    public let metadata: String?
    public let vector: [Float]

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
    public init(id: Int, content: String, source: String, encoding metadata: some Encodable, vector: [Float]) throws {
        try self.init(id: id, content: content, source: source,
                      metadata: MetadataJSON.encode(metadata), vector: vector)
    }

    /// Convenience for embedders that produce `[Double]`; converted to `[Float]`
    /// (the canonical vector type — sqlite-vec stores float32).
    /// Disfavored so numeric-literal arrays keep resolving to the [Float] overload.
    @_disfavoredOverload
    public init(id: Int, content: String, source: String, metadata: String? = nil, vector: [Double]) {
        self.init(id: id, content: content, source: source,
                  metadata: metadata, vector: vector.map(Float.init))
    }

    /// `[Double]` + Codable metadata convenience.
    @_disfavoredOverload
    public init(id: Int, content: String, source: String, encoding metadata: some Encodable, vector: [Double]) throws {
        try self.init(id: id, content: content, source: source,
                      metadata: MetadataJSON.encode(metadata), vector: vector.map(Float.init))
    }
}
