import Foundation

enum PasteTextTransforms {
    /// One-click Paste UI transform:
    /// 1) Replace U+3000 (full-width space) with ASCII space.
    /// 2) Transliterate Latin words to Katakana (loanword-style) while preserving all non-Latin text.
    static func transform(_ text: String) -> String {
        let normalizedSpaces = text.replacingOccurrences(of: "\u{3000}", with: " ")
        return transliteratingLatinWordsToKatakana(in: normalizedSpaces)
    }

    private static func transliteratingLatinWordsToKatakana(in text: String) -> String {
        guard text.isEmpty == false else { return text }

        // Match ASCII Latin words only; leave punctuation, numbers, kana/kanji unchanged.
        // Examples:
        // - "test case" -> "テスト ケース" (spaces preserved)
        // - "test-case" -> "テスト-ケース" (hyphen preserved)
        // - "C++" -> "シー++" (only "C" transliterated)
        let pattern = "[A-Za-z]+(?:'[A-Za-z]+)*"
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [])
        } catch {
            return text
        }

        let nsText = text as NSString
        var result = text

        // Replace from the end to keep ranges valid.
        for match in regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)).reversed() {
            guard match.range.location != NSNotFound, match.range.length > 0 else { continue }
            let word = nsText.substring(with: match.range)
            let katakana = latinWordToKatakana(word)
            result = (result as NSString).replacingCharacters(in: match.range, with: katakana)
        }

        return result
    }

    private static func latinWordToKatakana(_ word: String) -> String {
        guard word.isEmpty == false else { return word }
        let mutable = NSMutableString(string: word)
        let ok = CFStringTransform(mutable, nil, kCFStringTransformLatinKatakana, false)
        return ok ? (mutable as String) : word
    }
}
