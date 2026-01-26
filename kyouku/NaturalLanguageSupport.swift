import Foundation
import NaturalLanguage

enum SentenceContextExtractor {
    /// Returns the sentence substring that contains `target` (UTF-16 / NSRange) within `text`.
    ///
    /// - Important: `target` is interpreted as UTF-16, matching the app's range conventions.
    static func sentence(containing target: NSRange, in text: String) -> (sentence: String, sentenceRange: NSRange)? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        guard target.location != NSNotFound, target.length > 0 else { return nil }
        guard NSMaxRange(target) <= nsText.length else { return nil }

        guard let targetRange = Range(target, in: text) else { return nil }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var matched: Range<String.Index>?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            if tokenRange.contains(targetRange.lowerBound) || targetRange.overlaps(tokenRange) {
                matched = tokenRange
                return false
            }
            return true
        }

        guard let sentenceRange = matched else { return nil }
        let sentence = String(text[sentenceRange])
        let nsSentenceRange = NSRange(sentenceRange, in: text)
        return (sentence, nsSentenceRange)
    }
}

struct DetectedGrammarPattern: Identifiable, Hashable {
    let id: String
    let title: String
    let explanation: String
    let matchText: String
}

enum GrammarPatternDetector {
    /// Lightweight, explainable pattern detection.
    ///
    /// This is intentionally conservative and meant for quick “what am I looking at?” hints.
    static func detect(in sentence: String) -> [DetectedGrammarPattern] {
        let s = sentence
        guard s.isEmpty == false else { return [] }

        // Minimal starter set. We can expand iteratively once UX is validated.
        // Note: these are surface-form patterns, not a full parser.
        let patterns: [(title: String, explanation: String, regex: String)] = [
            (
                title: "〜ている",
                explanation: "Progressive/state. Often indicates an ongoing action or resulting state.",
                regex: "(て|で)(い|居)(る|ます|た|て|で)"
            ),
            (
                title: "〜てしまう",
                explanation: "Completion/regret. Often implies something ended up happening (sometimes unfortunately).",
                regex: "(て|で)しま(う|います|った|って|わ)"
            ),
            (
                title: "〜ように",
                explanation: "Purpose/so that; or ‘in such a way that’.",
                regex: "ように"
            ),
            (
                title: "〜ことがある",
                explanation: "Experience (‘have done before’) or occasional occurrence depending on context.",
                regex: "ことがあ(る|ります|った|って)"
            ),
            (
                title: "〜なければならない",
                explanation: "Obligation (‘must’).",
                regex: "なければなら(ない|なかった|ず|ぬ)"
            ),
            (
                title: "〜てください",
                explanation: "Request (‘please do’).",
                regex: "(て|で)ください"
            )
        ]

        var out: [DetectedGrammarPattern] = []
        out.reserveCapacity(4)

        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p.regex, options: []) else { continue }
            let ns = s as NSString
            let range = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: s, options: [], range: range)
            guard let first = matches.first else { continue }
            let matchText = ns.substring(with: first.range)
            out.append(
                DetectedGrammarPattern(
                    id: "\(p.title)#\(p.regex)",
                    title: p.title,
                    explanation: p.explanation,
                    matchText: matchText
                )
            )
        }

        return out
    }
}

enum JapaneseSimilarityService {
    /// Returns nearest-neighbor words in Apple’s Japanese embedding space (when available).
    ///
    /// This is useful for “similar words / semantic neighborhood” UX.
    static func neighbors(for term: String, maxCount: Int = 12) -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        guard let embedding = NLEmbedding.wordEmbedding(for: .japanese) else { return [] }
        // NLEmbedding returns (String, Double) pairs.
        let results = embedding.neighbors(for: trimmed, maximumCount: max(0, min(50, maxCount)))
        return results.map { $0.0 }
    }
}
