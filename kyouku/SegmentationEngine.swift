import Foundation

enum SegmentationEngine: String, CaseIterable, Identifiable {
    case dictionaryTrie = "dictionary-trie"
    case appleTokenizer = "apple-tokenizer"

    static let storageKey = "segmentationEnginePreference"
    static let defaultValue = SegmentationEngine.dictionaryTrie

    var id: String { rawValue }

    static func current() -> SegmentationEngine {
        let stored = UserDefaults.standard.string(forKey: storageKey)
        return SegmentationEngine(rawValue: stored ?? "") ?? .dictionaryTrie
    }

    static func save(_ engine: SegmentationEngine) {
        UserDefaults.standard.set(engine.rawValue, forKey: storageKey)
    }

    var displayName: String {
        switch self {
        case .dictionaryTrie:
            return "JMdict + MeCab"
        case .appleTokenizer:
            return "Apple Tokenizer"
        }
    }

    var description: String {
        switch self {
        case .dictionaryTrie:
            return "Longest matches from JMdict with MeCab readings. Most accurate for compounds."
        case .appleTokenizer:
            return "System tokenizer (NaturalLanguage). Faster startup, but fewer dictionary merges."
        }
    }
}
