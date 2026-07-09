/// A hybrid (vector + lexical) search hit, ranked by Reciprocal Rank Fusion.
/// Unlike `SearchResult.distance`, `score` is **higher = better**.
/// `vectorRank`/`textRank` are 1-based ranks in each underlying result list,
/// nil when the row appeared in only one of them.
public struct HybridSearchResult: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let content: String
    public let source: String
    public let metadata: String?
    public let score: Double
    public let vectorRank: Int?
    public let textRank: Int?
}
