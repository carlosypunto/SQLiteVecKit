/// A hybrid (vector + lexical) search hit, ranked by Reciprocal Rank Fusion.
/// Unlike `SearchResult.distance`, `score` is **higher = better**.
/// `vectorRank`/`textRank` are 1-based ranks in each underlying result list,
/// nil when the row appeared in only one of them.
public struct HybridSearchResult: Sendable, Equatable, Identifiable, Codable {
    /// Row identifier of the matching entry.
    public let id: Int

    /// Stored text chunk for the match.
    public let content: String

    /// Source label supplied when the entry was inserted.
    public let source: String

    /// Raw metadata string as stored (usually JSON); `nil` if the row has none.
    public let metadata: String?

    /// Reciprocal Rank Fusion score. Higher values rank earlier.
    public let score: Double

    /// 1-based rank from the vector result list, or `nil` if absent from that list.
    public let vectorRank: Int?

    /// 1-based rank from the lexical result list, or `nil` if absent from that list.
    public let textRank: Int?
}
