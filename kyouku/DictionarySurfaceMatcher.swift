import Foundation
import NaturalLanguage

/// Produces bounded segmentation spans by probing JMdict-backed surfaces inside
/// token boundaries produced by the system tokenizer. No readings or dictionary
/// metadata escape this stage.
struct DictionarySurfaceMatcher {
    static let maxSurfaceLength = 8
    private static let fallbackSampleLimit = 48
    private static let japaneseCharacterSet: CharacterSet = {
        var set = CharacterSet()
        set.formUnion(CharacterSet(charactersIn: "\u{3040}"..."\u{309F}")) // Hiragana
        set.formUnion(CharacterSet(charactersIn: "\u{30A0}"..."\u{30FF}")) // Katakana
        set.formUnion(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")) // CJK Unified Ideographs
        set.formUnion(CharacterSet(charactersIn: "\u{3400}"..."\u{4DBF}")) // CJK Extension A
        return set
    }()
    private static let kanaCharacterSet: CharacterSet = {
        var set = CharacterSet()
        set.formUnion(CharacterSet(charactersIn: "\u{3040}"..."\u{309F}"))
        set.formUnion(CharacterSet(charactersIn: "\u{30A0}"..."\u{30FF}"))
        return set
    }()

    private let dictionaryStore: DictionarySQLiteStore

    init(dictionaryStore: DictionarySQLiteStore = .shared) {
        self.dictionaryStore = dictionaryStore
    }

    /// Returns every dictionary-backed span whose surface exactly matches part
    /// of the input text. Overlapping spans are expected and conflict
    /// resolution is handled downstream.
    func segment(text: String) async throws -> [TextSpan] {
        guard text.isEmpty == false else {
            return []
        }

        let nsText = text as NSString
        let tokenRanges = Self.wordRanges(in: text)

        if tokenRanges.isEmpty {
            return []
        }

        var spans: [TextSpan] = []
        for tokenRange in tokenRanges {
            let trimmed = Self.trimRange(tokenRange, in: nsText)
            guard trimmed.length > 0 else {
                continue
            }
            let word = nsText.substring(with: trimmed)
            guard Self.containsJapaneseCharacters(word) else {
                continue
            }
            guard Self.isRubyEligibleToken(word, utf16Length: trimmed.length) else {
//                Self.debug("Skipping token '\(word)' (len \(trimmed.length)) due to ruby eligibility filter.")
                continue
            }

            if let span = try await lookupRange(trimmed, in: nsText) {
                spans.append(span)
                continue
            }
        }
        return spans
    }

    private func lookupRange(_ range: NSRange, in text: NSString) async throws -> TextSpan? {
        let candidate = text.substring(with: range)
        let entries = try await dictionaryStore.lookup(term: candidate, limit: 30)

        guard entries.isEmpty == false else {
            return nil
        }

        let span = TextSpan(range: range, surface: candidate)

        return span
    }

    private func fallbackMatches(in text: NSString, range: NSRange) async throws -> [TextSpan] {
        // NOTE: Disabled for render-time use. This performs many SQLite lookups and is too slow for UI-triggered furigana rendering.
        var matches: [TextSpan] = []
        let end = range.location + range.length
        let offsets = Self.sampleOffsets(forLength: range.length)

        for offset in offsets {
            let start = range.location + offset
            if start >= end { break }
            let remaining = end - start
            let maxLength = min(remaining, Self.maxSurfaceLength)
            guard maxLength > 0 else { continue }

            for currentLength in stride(from: maxLength, through: 1, by: -1) {
                let candidateRange = NSRange(location: start, length: currentLength)
                let substring = text.substring(with: candidateRange)
                guard Self.containsJapaneseCharacters(substring) else { continue }
                let entries = try await dictionaryStore.lookup(term: substring, limit: 30)
                guard entries.isEmpty == false else { continue }
                matches.append(TextSpan(range: candidateRange, surface: substring))
            }
        }

        return matches
    }

    private static func wordRanges(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.japanese)
        var ranges: [NSRange] = []

        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let nsRange = NSRange(range, in: text)
            ranges.append(nsRange)
            return true
        }

        return ranges
    }

    private static func trimRange(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        let whitespace = CharacterSet.whitespacesAndNewlines

        while start < end {
            let value = text.character(at: start)
            if let scalar = UnicodeScalar(value), whitespace.contains(scalar) {
                start += 1
            } else {
                break
            }
        }

        while end > start {
            let value = text.character(at: end - 1)
            if let scalar = UnicodeScalar(value), whitespace.contains(scalar) {
                end -= 1
            } else {
                break
            }
        }

        guard end > start else {
            return NSRange(location: range.location, length: 0)
        }

        return NSRange(location: start, length: end - start)
    }

    private static func containsJapaneseCharacters(_ string: String) -> Bool {
        string.rangeOfCharacter(from: japaneseCharacterSet) != nil
    }

    private static func isRubyEligibleToken(_ token: String, utf16Length: Int) -> Bool {
        guard utf16Length >= 2 else { return false }
        guard token.count > 1 else { return false }
        guard containsKanji(token) else { return false }
        guard isKanaOnly(token) == false else { return false }
        return true
    }

    private static func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func isKanaOnly(_ text: String) -> Bool {
        guard text.isEmpty == false else { return false }
        return text.unicodeScalars.allSatisfy { kanaCharacterSet.contains($0) }
    }

    private static func sampleOffsets(forLength length: Int) -> [Int] {
        guard length > 0 else { return [] }
        if length <= fallbackSampleLimit {
            return Array(0..<length)
        }

        let headCount = fallbackSampleLimit / 2
        let tailCount = fallbackSampleLimit - headCount
        var offsets: [Int] = Array(0..<headCount)
        let tailStart = max(headCount, length - tailCount)
        offsets.append(contentsOf: tailStart..<length)
        return offsets
    }
}


