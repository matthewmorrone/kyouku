import Foundation
import OSLog
import Dispatch

/// Builds and caches the in-memory trie from JMdict surfaces. SQLite is only
/// touched here during the one-time bootstrap so the segmentation hot path
/// stays fully memory resident.
actor LexiconProvider {
    static let shared = LexiconProvider()

    private var cachedTrie: LexiconTrie?
    private var cachedSokuonTerminalAllowedForms: Set<String>?
    private var buildTask: Task<Bootstrap, Error>?
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "LexiconProvider")

    private struct Bootstrap {
        let trie: LexiconTrie
        let sokuonTerminalAllowedForms: Set<String>
    }

    /// Returns the already-cached trie if available, without triggering a build.
    ///
    /// This must never touch SQLite; it is safe to call from hot paths that want
    /// an optional, in-memory lexicon check.
    func cachedTrieIfAvailable() -> LexiconTrie? {
        cachedTrie
    }

    func sokuonTerminalAllowedForms() async throws -> Set<String> {
        if let cached = cachedSokuonTerminalAllowedForms {
            return cached
        }
        let bootstrap = try await bootstrapIfNeeded()
        return bootstrap.sokuonTerminalAllowedForms
    }

    func trie() async throws -> LexiconTrie {
        let bootstrap = try await bootstrapIfNeeded()
        return bootstrap.trie
    }

    private func bootstrapIfNeeded() async throws -> Bootstrap {
        let overallInterval = signposter.beginInterval("Trie() Overall")

        if let trie = cachedTrie, let allowed = cachedSokuonTerminalAllowedForms {
            signposter.endInterval("Trie() Overall", overallInterval)
            return Bootstrap(trie: trie, sokuonTerminalAllowedForms: allowed)
        }

        if let task = buildTask {
            let bootstrap = try await task.value
            signposter.endInterval("Trie() Overall", overallInterval)
            return bootstrap
        }

        // Capture actor-isolated state before entering the Task closure.
        let signposter = self.signposter

        let task = Task<Bootstrap, Error> {
            let sqliteInterval = signposter.beginInterval("Trie() SQLite bootstrap")
            let forms = try await DictionarySQLiteStore.shared.listAllSurfaceForms()
            let allowed = try await DictionarySQLiteStore.shared.listSokuonTerminalAllowedSurfaceForms()
            signposter.endInterval("Trie() SQLite bootstrap", sqliteInterval)

            let buildInterval = signposter.beginInterval("Trie() Build LexiconTrie")
            // Build the trie off the main thread to avoid UI hitching
            let trie: LexiconTrie = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: LexiconTrie(words: forms))
                }
            }
            signposter.endInterval("Trie() Build LexiconTrie", buildInterval)

            return Bootstrap(trie: trie, sokuonTerminalAllowedForms: Set(allowed))
        }
        buildTask = task

        do {
            let bootstrap = try await task.value
            cachedTrie = bootstrap.trie
            cachedSokuonTerminalAllowedForms = bootstrap.sokuonTerminalAllowedForms
            buildTask = nil
            signposter.endInterval("Trie() Overall", overallInterval)
            // await CustomLogger.shared.info("Lexicon trie built and cached in memory.")
            return bootstrap
        } catch {
            buildTask = nil
            signposter.endInterval("Trie() Overall", overallInterval)
            await CustomLogger.shared.error("Failed to build lexicon trie: \(String(describing: error))")
            throw error
        }
    }
}
