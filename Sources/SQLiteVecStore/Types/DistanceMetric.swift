/// Distance metric used by the vec0 embedding column.
/// Cosine is the default because it is what most RAG embedding models expect.
public enum DistanceMetric: String, Sendable, CaseIterable, Equatable {
    /// Euclidean distance. Lower values are more similar.
    case l2

    /// Cosine distance. Lower values are more similar; identical normalized vectors are near zero.
    case cosine
}
