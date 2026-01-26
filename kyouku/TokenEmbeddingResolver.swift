import Foundation

struct TokenEmbeddingRange: Hashable {
    let location: Int
    let length: Int

    init(_ range: NSRange) {
        self.location = range.location
        self.length = range.length
    }

    var nsRange: NSRange { NSRange(location: location, length: length) }
}

struct TokenWithRange {
    let range: NSRange
    let token: EmbeddingToken

    init(range: NSRange, token: EmbeddingToken) {
        self.range = range
        self.token = token
    }
}

/// Resolves embedding vectors for tokens while preserving original text ranges exactly.
///
/// No UI code.
final class TokenEmbeddingResolver: @unchecked Sendable {
    private let access: EmbeddingAccess

    init(access: EmbeddingAccess = .shared) {
        self.access = access
    }

    /// Returns mapping from original ranges to embedding vectors.
    /// Missing embeddings are omitted.
    func resolve(tokens: [TokenWithRange]) -> [TokenEmbeddingRange: [Float]] {
        guard tokens.isEmpty == false else { return [:] }

        // Build ordered candidate lists per token (policy-only).
        let perTokenCandidates: [[String]] = tokens.map { EmbeddingFallbackPolicy.candidates(for: $0.token) }

        // Batch fetch all unique candidates.
        var unique: [String] = []
        unique.reserveCapacity(tokens.count * 2)
        var seen: Set<String> = []
        seen.reserveCapacity(tokens.count * 2)

        for list in perTokenCandidates {
            for c in list {
                if seen.contains(c) { continue }
                seen.insert(c)
                unique.append(c)
            }
        }

        let fetched = access.vectors(for: unique)

        var out: [TokenEmbeddingRange: [Float]] = [:]
        out.reserveCapacity(tokens.count)

        for (idx, t) in tokens.enumerated() {
            let candidates = perTokenCandidates[idx]
            var chosen: [Float]? = nil
            for c in candidates {
                if let vec = fetched[c] {
                    chosen = vec
                    #if DEBUG
                    if c != t.token.surface {
                        EmbeddingDiagnostics.shared.recordFallbackUsed()
                    }
                    #endif
                    break
                }
            }
            if let chosen {
                out[TokenEmbeddingRange(t.range)] = chosen
            }
        }

        return out
    }
}
