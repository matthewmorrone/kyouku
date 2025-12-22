import Foundation

enum TokenizerBoundaryManager {
    /// Rebuilds the JMdict trie (including custom boundaries) and updates the shared cache.
    @discardableResult
    static func rebuildSharedTrie() async -> Trie? {
        let rebuilt = await TrieProvider.shared.rebuildNow()
        await MainActor.run {
            TrieCache.shared = rebuilt
        }
        return rebuilt
    }

    /// Convenience helper when call sites do not need to await completion.
    static func refreshSharedTrieInBackground() {
        Task {
            _ = await rebuildSharedTrie()
        }
    }
}
