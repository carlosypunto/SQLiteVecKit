/// A KNN search hit. `distance` semantics depend on the store's DistanceMetric
/// (cosine: [0, 2]; l2: [0, inf)) — lower is always more similar.
/// For `searchText` results, `distance` carries the BM25 score instead
/// (negative; still lower = better, but not comparable across query kinds).
public struct SearchResult: Sendable, Equatable, Identifiable, Codable {
    /// Row identifier of the matching entry.
    public let id: Int

    /// Stored text chunk for the match.
    public let content: String

    /// Source label supplied when the entry was inserted.
    public let source: String

    /// Raw metadata string as stored (usually JSON); `nil` if the row has none.
    public let metadata: String?

    /// Rank score for this result.
    /// For vector search this is the sqlite-vec distance; for text search this is BM25.
    public let distance: Double

    /// Decodes the stored metadata JSON into `type`.
    /// Returns `nil` if the row has no metadata; throws on malformed JSON.
    ///
    /// - Parameter type: Metadata type to decode.
    /// - Returns: Decoded metadata, or `nil` when this row has no metadata.
    /// - Throws: Any decoding error if the stored metadata is not valid for `type`.
    public func decodeMetadata<M: Decodable>(_ type: M.Type) throws -> M? {
        guard let metadata else { return nil }
        return try MetadataJSON.decode(type, from: metadata)
    }
}
