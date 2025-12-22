import Foundation

actor TrieProvider {
    static let shared = TrieProvider()

    private var cached: Trie?
    private var isBuilding = false

    /// Returns a cached Trie if available; otherwise builds it from JMdict (kanji + readings) UNION custom words and caches it.
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
            let customs = await MainActor.run { CustomTokenizerLexicon.words() }
            let union = Array(Set(forms + customs))
            if union.isEmpty { return nil }
            let trie: Trie = await MainActor.run {
                return Trie(words: union)
            }
            self.cached = trie
            return trie
        } catch {
            // Fallback to custom-only trie if DB fails
            let customs = await MainActor.run { CustomTokenizerLexicon.words() }
            guard customs.isEmpty == false else { return nil }
            let trie: Trie = await MainActor.run { Trie(words: customs) }
            self.cached = trie
            return trie
        }
    }

    /// Force a rebuild of the Trie including custom words and update the cache.
    func rebuildNow() async -> Trie? {
        isBuilding = true
        defer { isBuilding = false }
        do {
            let forms = try await listAllSurfaceForms()
            let customs = await MainActor.run { CustomTokenizerLexicon.words() }
            let union = Array(Set(forms + customs))
            if union.isEmpty { cached = nil; return nil }
            let trie: Trie = await MainActor.run { Trie(words: union) }
            cached = trie
            return trie
        } catch {
            let customs = await MainActor.run { CustomTokenizerLexicon.words() }
            guard customs.isEmpty == false else { cached = nil; return nil }
            let trie: Trie = await MainActor.run { Trie(words: customs) }
            cached = trie
            return trie
        }
    }

    /// Clear the cached Trie so the next `getTrie()` call rebuilds it.
    func invalidate() {
        cached = nil
    }
    private func listAllSurfaceForms() async throws -> [String] {
        // Use the SQLite store to fetch all unique surface forms (kanji and readings)
        return try await DictionarySQLiteStore.shared.listAllSurfaceForms()
    }
}

