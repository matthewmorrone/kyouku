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

    /// Adds a word to the custom lexicon if not already present. Returns true if added.
    @discardableResult
    static func add(word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        var set = Set(words())
        let inserted = set.insert(trimmed).inserted
        guard inserted else { return false }
        let joined = set.sorted().joined(separator: "\n")
        UserDefaults.standard.set(joined, forKey: storageKey)
        // Invalidate cached trie so next access rebuilds
        JMdictTrieCache.shared = CustomTrieProvider.makeTrie()
        return true
    }

    /// Removes a word from the custom lexicon. Returns true if removed.
    @discardableResult
    static func remove(word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        var set = Set(words())
        let removed = set.remove(trimmed) != nil
        guard removed else { return false }
        let joined = set.sorted().joined(separator: "\n")
        UserDefaults.standard.set(joined, forKey: storageKey)
        JMdictTrieCache.shared = CustomTrieProvider.makeTrie()
        return true
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
