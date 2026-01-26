import Foundation

#if DEBUG
enum EmbeddingDebugIntrospection {
    static func topNeighbors(of word: String, topN: Int) -> [EmbeddingNeighborhoodPrefetcher.Neighbor] {
        EmbeddingNeighborhoodPrefetcher.shared.cachedNeighborhood(for: word) ?? []
    }

    static func similarity(a: [Float], b: [Float]) -> Float {
        EmbeddingMath.cosineSimilarity(a: a, b: b)
    }

    static func vectorNorm(_ v: [Float]) -> Float {
        EmbeddingMath.l2Norm(v)
    }
}
#endif
