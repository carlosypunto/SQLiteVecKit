/// Distance metric used by the vec0 embedding column.
/// Cosine is the default because it is what most RAG embedding models expect.
public enum DistanceMetric: String, Sendable, CaseIterable, Equatable {
    case l2
    case cosine
}
