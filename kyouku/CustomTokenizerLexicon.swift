import Foundation

enum CustomTokenizerLexicon {
    static let storageKey = "customTokenizerWords"

    /// Returns user-defined words (one per line) from UserDefaults.
    static func words() -> [String] {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return raw
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum CustomTrieProvider {
    /// Builds a Trie from the current lexicon. Cheap if list is small; call on demand.
    static func makeTrie() -> Trie? {
        let ws = CustomTokenizerLexicon.words()
        guard ws.isEmpty == false else { return nil }
        return Trie(words: ws)
    }
}
