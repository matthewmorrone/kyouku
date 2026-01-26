import Foundation

enum ThemeClustering {
    static func chooseK(noteCount: Int) -> Int {
        guard noteCount >= 2 else { return max(0, noteCount) }
        let raw = Int(Double(noteCount).squareRoot().rounded(.toNearestOrEven))
        return min(6, max(2, raw))
    }

    /// K-means over normalized vectors using cosine similarity (dot product).
    /// Returns an assignment per vector index (0..k-1) and the normalized centroids.
    static func kMeansCosine(vectors: [[Float]], k: Int, maxIters: Int = 18) -> (assignments: [Int], centroids: [[Float]]) {
        precondition(vectors.isEmpty == false)
        precondition(k >= 1)

        let n = vectors.count
        let dim = vectors[0].count

        func dot(_ a: [Float], _ b: [Float]) -> Float {
            EmbeddingMath.cosineSimilarity(a: a, b: b)
        }

        func normalize(_ v: [Float]) -> [Float] {
            var sum: Float = 0
            for x in v { sum += x * x }
            let norm = sum.squareRoot()
            guard norm > 0 else { return v }
            return v.map { $0 / norm }
        }

        // Deterministic k-means++ style init.
        var centroids: [[Float]] = []
        centroids.reserveCapacity(k)
        centroids.append(vectors[0])

        while centroids.count < k {
            var bestIndex = 0
            var bestScore: Float = -Float.greatestFiniteMagnitude
            for i in 0..<n {
                // Distance to nearest existing centroid.
                var nearest: Float = 1
                for c in centroids {
                    let sim = dot(vectors[i], c)
                    let dist = 1 - sim
                    if dist < nearest { nearest = dist }
                }
                if nearest > bestScore {
                    bestScore = nearest
                    bestIndex = i
                }
            }
            centroids.append(vectors[bestIndex])
        }

        var assignments = Array(repeating: 0, count: n)
        var lastAssignments: [Int] = []

        for _ in 0..<maxIters {
            // Assign.
            for i in 0..<n {
                var best = 0
                var bestSim: Float = -Float.greatestFiniteMagnitude
                for c in 0..<k {
                    let sim = dot(vectors[i], centroids[c])
                    if sim > bestSim {
                        bestSim = sim
                        best = c
                    }
                }
                assignments[i] = best
            }

            if assignments == lastAssignments {
                break
            }
            lastAssignments = assignments

            // Recompute centroids.
            var sums = Array(repeating: Array(repeating: Float(0), count: dim), count: k)
            var counts = Array(repeating: Float(0), count: k)

            for i in 0..<n {
                let c = assignments[i]
                counts[c] += 1
                let v = vectors[i]
                for d in 0..<dim {
                    sums[c][d] += v[d]
                }
            }

            for c in 0..<k {
                if counts[c] <= 0 {
                    // Empty cluster: re-seed with the farthest point.
                    var farthestIndex = 0
                    var farthestDist: Float = -1
                    for i in 0..<n {
                        var nearest: Float = 1
                        for cc in 0..<k where cc != c {
                            let sim = dot(vectors[i], centroids[cc])
                            let dist = 1 - sim
                            if dist < nearest { nearest = dist }
                        }
                        if nearest > farthestDist {
                            farthestDist = nearest
                            farthestIndex = i
                        }
                    }
                    centroids[c] = vectors[farthestIndex]
                    continue
                }

                let mean = sums[c].map { $0 / counts[c] }
                centroids[c] = normalize(mean)
            }
        }

        return (assignments, centroids)
    }
}
