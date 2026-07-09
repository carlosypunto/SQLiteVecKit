/// A KNN search hit. `distance` semantics depend on the store's DistanceMetric
/// (cosine: [0, 2]; l2: [0, inf)) — lower is always more similar.
/// For `searchText` results, `distance` carries the BM25 score instead
/// (negative; still lower = better, but not comparable across query kinds).
public struct SearchResult: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let content: String
    public let source: String
    /// Raw metadata string as stored (usually JSON); `nil` if the row has none.
    public let metadata: String?
    public let distance: Double

    /// Decodes the stored metadata JSON into `type`.
    /// Returns `nil` if the row has no metadata; throws on malformed JSON.
    public func decodeMetadata<M: Decodable>(_ type: M.Type) throws -> M? {
        guard let metadata else { return nil }
        return try MetadataJSON.decode(type, from: metadata)
    }
}
