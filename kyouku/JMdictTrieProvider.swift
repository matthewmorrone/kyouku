import Foundation

actor JMdictTrieProvider {
    static let shared = JMdictTrieProvider()

    private var cached: Trie?
    private var isBuilding = false

    /// Returns a cached Trie if available; otherwise builds it from JMdict (kanji + readings) and caches it.
    func getTrie() async -> Trie? {
        if let t = cached { return t }
        if isBuilding {
            while isBuilding { try? await Task.sleep(nanoseconds: 10_000_000) }
            return cached
        }
        isBuilding = true
        defer { isBuilding = false }
        do {
            let forms = try await listAllSurfaceForms()
            if forms.isEmpty { return nil }
            let trie = Trie(words: forms)
            self.cached = trie
            return trie
        } catch {
            return nil
        }
    }

    private func listAllSurfaceForms() async throws -> [String] {
        // Use the SQLite store to fetch all unique surface forms (kanji and readings)
        // Falls back to CustomTokenizerLexicon if DB is not available.
        do {
            return try await DictionarySQLiteStore.shared.listAllSurfaceForms()
        } catch {
            // Fallback: allow user-provided list
            return await CustomTokenizerLexicon.words()
        }
    }
}
