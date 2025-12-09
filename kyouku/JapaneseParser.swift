import Foundation

enum JapaneseParser {
    static func parse(text: String) -> [ParsedToken] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        
        // For now: treat the whole text as a single token.
        // We’ll replace this with MeCab later.
        return [
            ParsedToken(
                surface: trimmed,
                reading: trimmed,
                meaning: ""
            )
        ]
    }
}
