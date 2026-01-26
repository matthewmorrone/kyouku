import Foundation

enum EmbeddingMath {
    /// Canonical cosine similarity for embedding vectors.
    ///
    /// - Important: Assumes vectors are already normalized.
    /// - Returns: Dot product (cosine similarity) of two Float vectors.
    static func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        precondition(a.count == b.count)
        var acc: Float = 0
        for i in 0..<a.count {
            acc += a[i] * b[i]
        }
        return acc
    }

    #if DEBUG
    static func l2Norm(_ v: [Float]) -> Float {
        var sum: Float = 0
        for x in v {
            sum += x * x
        }
        return sum.squareRoot()
    }
    #endif
}
