import Foundation
import OSLog
import Dispatch

/// Builds and caches the in-memory trie from JMdict surfaces. SQLite is only
/// touched here during the one-time bootstrap so the segmentation hot path
/// stays fully memory resident.
actor LexiconProvider {
    static let shared = LexiconProvider()

    private var cachedTrie: LexiconTrie?
    private var buildTask: Task<LexiconTrie, Error>?
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "LexiconProvider")

    /// Returns the already-cached trie if available, without triggering a build.
    ///
    /// This must never touch SQLite; it is safe to call from hot paths that want
    /// an optional, in-memory lexicon check.
    func cachedTrieIfAvailable() -> LexiconTrie? {
        cachedTrie
    }

    func trie() async throws -> LexiconTrie {
        let overallInterval = signposter.beginInterval("Trie() Overall")

        if let trie = cachedTrie {
            signposter.endInterval("Trie() Overall", overallInterval)
            return trie
        }

        if let task = buildTask {
            return try await task.value
        }

        // Capture actor-isolated state before entering the Task closure.
        let signposter = self.signposter

        let task = Task<LexiconTrie, Error> {
            let sqliteInterval = signposter.beginInterval("Trie() SQLite listAllSurfaceForms")
            let forms = try await DictionarySQLiteStore.shared.listAllSurfaceForms()
            signposter.endInterval("Trie() SQLite listAllSurfaceForms", sqliteInterval)

            let buildInterval = signposter.beginInterval("Trie() Build LexiconTrie")
            // Build the trie off the main thread to avoid UI hitching
            let trie: LexiconTrie = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: LexiconTrie(words: forms))
                }
            }

            signposter.endInterval("Trie() Build LexiconTrie", buildInterval)
            return trie
        }
        buildTask = task

        do {
            let trie = try await task.value
            cachedTrie = trie
            buildTask = nil
            signposter.endInterval("Trie() Overall", overallInterval)
            await CustomLogger.shared.info("Lexicon trie built and cached in memory.")
            return trie
        } catch {
            buildTask = nil
            signposter.endInterval("Trie() Overall", overallInterval)
            await CustomLogger.shared.error("Failed to build lexicon trie: \(String(describing: error))")
            throw error
        }
    }
}
