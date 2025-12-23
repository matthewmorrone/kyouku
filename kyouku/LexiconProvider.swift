import Foundation
import OSLog

/// Builds and caches the in-memory trie from JMdict surfaces. SQLite is only
/// touched here during the one-time bootstrap so the segmentation hot path
/// stays fully memory resident.
actor LexiconProvider {
    static let shared = LexiconProvider()

    private var cachedTrie: LexiconTrie?
    private var buildTask: Task<LexiconTrie, Error>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "LexiconProvider")

    func trie() async throws -> LexiconTrie {
        if let trie = cachedTrie {
            return trie
        }

        if let task = buildTask {
            return try await task.value
        }

        let task = Task<LexiconTrie, Error> {
            let forms = try await DictionarySQLiteStore.shared.listAllSurfaceForms()
            return LexiconTrie(words: forms)
        }
        buildTask = task

        do {
            let trie = try await task.value
            cachedTrie = trie
            buildTask = nil
            logger.info("Lexicon trie built and cached in memory.")
            return trie
        } catch {
            buildTask = nil
            logger.error("Failed to build lexicon trie: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
