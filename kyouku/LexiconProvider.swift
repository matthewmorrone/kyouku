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
    private let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "LexiconProvider")

    private func info(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.info("[\(file):\(line)] \(function): \(message)")
    }

    private func logError(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        logger.error("[\(file):\(line)] \(function): \(message)")
    }

    func trie() async throws -> LexiconTrie {
        let overallStart = CFAbsoluteTimeGetCurrent()
        let overallInterval = signposter.beginInterval("Trie() Overall")

        if let trie = cachedTrie {
            let ms = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
            info("LexiconProvider.trie(): returning cached trie in \(String(format: "%.3f", ms)) ms")
            signposter.endInterval("Trie() Overall", overallInterval)
            return trie
        }

        if let task = buildTask {
            info("LexiconProvider.trie(): awaiting in-flight build task…")
            return try await task.value
        }

        let task = Task<LexiconTrie, Error> {
            let sqliteStart = CFAbsoluteTimeGetCurrent()
            let sqliteInterval = signposter.beginInterval("Trie() SQLite listAllSurfaceForms")
            let forms = try await DictionarySQLiteStore.shared.listAllSurfaceForms()
            signposter.endInterval("Trie() SQLite listAllSurfaceForms", sqliteInterval)
            let sqliteMs = (CFAbsoluteTimeGetCurrent() - sqliteStart) * 1000
            self.info("LexiconProvider.trie(): SQLite listAllSurfaceForms took \(String(format: "%.3f", sqliteMs)) ms; forms=\(forms.count)")

            let buildStart = CFAbsoluteTimeGetCurrent()
            let buildInterval = signposter.beginInterval("Trie() Build LexiconTrie")
            // Build the trie off the main thread to avoid UI hitching
            let trie: LexiconTrie = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    let built = LexiconTrie(words: forms)
                    continuation.resume(returning: built)
                }
            }
            signposter.endInterval("Trie() Build LexiconTrie", buildInterval)
            let buildMs = (CFAbsoluteTimeGetCurrent() - buildStart) * 1000
            self.info("LexiconProvider.trie(): LexiconTrie build took \(String(format: "%.3f", buildMs)) ms")
            return trie
        }
        buildTask = task

        do {
            let trie = try await task.value
            cachedTrie = trie
            buildTask = nil
            let totalMs = (CFAbsoluteTimeGetCurrent() - overallStart) * 1000
            info("LexiconProvider.trie(): built and cached in \(String(format: "%.3f", totalMs)) ms")
            signposter.endInterval("Trie() Overall", overallInterval)
            info("Lexicon trie built and cached in memory.")
            return trie
        } catch {
            buildTask = nil
            signposter.endInterval("Trie() Overall", overallInterval)
            logError("Failed to build lexicon trie: \(String(describing: error))")
            throw error
        }
    }
}

