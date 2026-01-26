import Foundation
import SQLite3

/// Session-scoped neighborhood caching and prefetching.
///
/// Notes:
/// - No ANN index; brute-force scan across known embedding keys.
/// - No long-lived background threads; this is synchronous/async-invoked work.
final class EmbeddingNeighborhoodPrefetcher: @unchecked Sendable {
    static let shared = EmbeddingNeighborhoodPrefetcher()

    struct Neighbor {
        let word: String
        let score: Float
    }

    private struct State {
        var allWordsLoaded = false
        var allWords: [String] = []
        var neighborhoods: [String: [Neighbor]] = [:]
    }

    private let lock = NSLock()
    private var state = State()

    /// Prefetch the vector for `word` and compute + cache its top-N neighbors.
    ///
    /// This assumes embedding vectors are already normalized.
    func prefetchNeighborhood(for word: String, topN: Int, access: EmbeddingAccess? = nil) async {
        EmbeddingFeatureGates.shared.ensureMetadataChecked()
        guard EmbeddingFeatureGates.shared.metadataStatus().enabled else {
            return
        }

        let resolvedAccess: EmbeddingAccess
        if let access {
            resolvedAccess = access
        } else {
            // `EmbeddingAccess.shared` is main-actor isolated; resolve it safely.
            resolvedAccess = await MainActor.run { EmbeddingAccess.shared }
        }

        let base = resolvedAccess.vectors(for: [word])[word]
        guard let base else { return }

        // Cache the base vector implicitly via EmbeddingAccess; compute neighbors now.
        let words = await loadAllWordsIfNeeded()
        if words.isEmpty { return }

        let candidates = words.filter { $0 != word }

        // Compute similarity in chunks using batch reads.
        var best: [Neighbor] = []
        best.reserveCapacity(max(0, topN))

        let chunkSize = 200
        var idx = 0
        while idx < candidates.count {
            let end = Swift.min(candidates.count, idx + chunkSize)
            let chunk = Array(candidates[idx..<end])
            idx = end

            let vectors = resolvedAccess.vectors(for: chunk)
            for (k, v) in vectors {
                let score = EmbeddingMath.cosineSimilarity(a: base, b: v)
                insertNeighbor(Neighbor(word: k, score: score), into: &best, topN: topN)
            }
        }

        let finalBest = best
        lock.withLock {
            state.neighborhoods[word] = finalBest
        }
    }

    func cachedNeighborhood(for word: String) -> [Neighbor]? {
        lock.withLock {
            state.neighborhoods[word]
        }
    }

    // MARK: - Internals

    private func loadAllWordsIfNeeded() async -> [String] {
        // Cheap fast-path.
        let existing: [String]? = lock.withLock {
            state.allWordsLoaded ? state.allWords : nil
        }
        if let existing { return existing }

        // Load by scanning SQLite (read-only) once per session.
        // This is still a utility-only feature; it is not wired into UI.
        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
            return []
        }

        var words: [String] = []
        words.reserveCapacity(30000)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(url.path, &handle, flags, nil) != SQLITE_OK {
            sqlite3_close(handle)
            return []
        }
        guard let db = handle else { return [] }
        defer { sqlite3_close(db) }

        let sql = "SELECT word FROM embeddings;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ptr = sqlite3_column_text(stmt, 0) else { continue }
            words.append(String(cString: ptr))
        }

        let finalWords = words
        lock.withLock {
            state.allWordsLoaded = true
            state.allWords = finalWords
        }

        return words
    }

    private func insertNeighbor(_ n: Neighbor, into arr: inout [Neighbor], topN: Int) {
        guard topN > 0 else { return }

        if arr.count < topN {
            arr.append(n)
            arr.sort { $0.score > $1.score }
            return
        }

        guard let worst = arr.last, n.score > worst.score else {
            return
        }

        arr[arr.count - 1] = n
        arr.sort { $0.score > $1.score }
    }
}
