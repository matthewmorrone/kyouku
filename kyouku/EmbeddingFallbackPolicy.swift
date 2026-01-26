import Foundation

struct EmbeddingToken {
    let surface: String
    let lemma: String?
    let reading: String?
    let constituents: [String]

    init(surface: String, lemma: String? = nil, reading: String? = nil, constituents: [String] = []) {
        self.surface = surface
        self.lemma = lemma
        self.reading = reading
        self.constituents = constituents
    }
}

enum EmbeddingFallbackPolicy {
    /// Ordered candidate lookup keys.
    ///
    /// Invariant: no string rewriting of any kind. Returned strings are exactly the input fields.
    static func candidates(for token: EmbeddingToken) -> [String] {
        var out: [String] = []

        out.append(token.surface)

        if let lemma = token.lemma {
            out.append(lemma)
        }

        if let reading = token.reading {
            out.append(reading)
        }

        for c in token.constituents {
            out.append(c)
        }

        return out
    }
}
