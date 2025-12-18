import Foundation
import NaturalLanguage

enum AppleSegmenter {
    static func segment(text: String) -> [Segment] {
        guard text.isEmpty == false else { return [] }
        let normalized = text.precomposedStringWithCanonicalMapping
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized
        tokenizer.setLanguage(.japanese)

        var output: [Segment] = []
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { range, _ in
            if range.isEmpty { return true }
            let token = String(normalized[range])
            if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            output.append(Segment(range: range, surface: token, isDictionaryMatch: false))
            return true
        }
        return output
    }
}
