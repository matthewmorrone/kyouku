import Foundation
import SQLite3

/// Computes semantic nearest neighbors for a term using cosine similarity.
///
/// Design goals:
/// - Purely additive: does not alter token boundaries or dictionary lookup logic.
/// - Session-cached: aggressively memoizes computed neighborhoods.
/// - Graceful: returns nil when embeddings are unavailable.
///
/// Assumptions:
/// - Embedding vectors in SQLite are already L2-normalized, so cosine similarity is the dot product.
actor EmbeddingNeighborsService {
    static let shared = EmbeddingNeighborsService()

    struct Neighbor: Hashable {
        let word: String
        let score: Float
    }

    private struct CacheEntry {
        let neighbors: [Neighbor]
        let computedTopN: Int
    }

    private var allWordsLoaded: Bool = false
    private var allWords: [String] = []

    private let embeddingDim: Int = 300

    private var cache: [String: CacheEntry] = [:]
    private var knownMissingEmbedding: Set<String> = []
    private var inFlight: [String: Task<[Neighbor]?, Never>] = [:]

    /// Returns the nearest neighbors for `term`.
    ///
    /// - Parameters:
    ///   - term: Exact key to query in the embeddings table. No normalization is applied.
    ///   - topN: Number of neighbors to return (20–50 recommended).
    /// - Returns: Neighbors sorted by descending similarity, or nil if unavailable.
    func neighbors(for term: String, topN: Int = 30) async -> [Neighbor]? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let n = max(0, min(100, topN))
        guard n > 0 else { return [] }

        if knownMissingEmbedding.contains(trimmed) {
            return nil
        }

        if let cached = cache[trimmed], cached.computedTopN >= n {
            return Array(cached.neighbors.prefix(n))
        }

        if let existing = inFlight[trimmed] {
            let result = await existing.value
            if let result { return Array(result.prefix(n)) }
            return nil
        }

        guard let dbPath = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3")?.path else {
            return nil
        }

        // Fetch base vector.
        let baseTask = Task.detached(priority: .utility) { [embeddingDim] in
            Self.fetchVectorsSync(for: [trimmed], dbPath: dbPath, dim: embeddingDim)[trimmed]
        }
        let base: [Float]? = await baseTask.value

        guard let base else {
            knownMissingEmbedding.insert(trimmed)
            return nil
        }

        // Load candidate vocabulary once per session (actor-isolated).
        let words = await loadAllWordsIfNeeded()
        if words.isEmpty { return [] }

        let task = Task<[Neighbor]?, Never>(priority: .userInitiated) { [embeddingDim] in
            let candidates = words.filter { $0 != trimmed }

            var best: [Neighbor] = []
            best.reserveCapacity(n)

            let chunkSize = 300
            var idx = 0
            while idx < candidates.count {
                let end = Swift.min(candidates.count, idx + chunkSize)
                let chunk = Array(candidates[idx..<end])
                idx = end

                let vectorsTask = Task.detached(priority: .utility) {
                    Self.fetchVectorsSync(for: chunk, dbPath: dbPath, dim: embeddingDim)
                }
                let vectors: [String: [Float]] = await vectorsTask.value

                for (k, v) in vectors {
                    let score = Self.dot(base, v)
                    EmbeddingNeighborsService.insertNeighborStatic(Neighbor(word: k, score: score), into: &best, topN: n)
                }
            }

            return best
        }

        inFlight[trimmed] = task
        let computed = await task.value
        inFlight[trimmed] = nil

        guard let computed else { return nil }

        cache[trimmed] = CacheEntry(neighbors: computed, computedTopN: n)
        return Array(computed.prefix(n))
    }

    // MARK: - SQLite embedding fetch

    private nonisolated static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var acc: Float = 0
        for i in 0..<a.count {
            acc += a[i] * b[i]
        }
        return acc
    }

    private nonisolated static func fetchVectorsSync(for keys: [String], dbPath: String, dim: Int) -> [String: [Float]] {
        guard keys.isEmpty == false else { return [:] }

        let expectedBytes = dim * MemoryLayout<Float>.size
        var out: [String: [Float]] = [:]
        out.reserveCapacity(keys.count)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        if sqlite3_open_v2(dbPath, &handle, flags, nil) != SQLITE_OK {
            sqlite3_close(handle)
            return [:]
        }
        guard let db = handle else { return [:] }
        defer { sqlite3_close(db) }

        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let sql = "SELECT word, vec FROM embeddings WHERE word IN (\(placeholders));"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            sqlite3_finalize(stmt)
            return [:]
        }
        defer { sqlite3_finalize(stmt) }

        for (i, key) in keys.enumerated() {
            let rc = sqlite3_bind_text(stmt, Int32(i + 1), key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if rc != SQLITE_OK {
                return [:]
            }
        }

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let wordPtr = sqlite3_column_text(stmt, 0) else { continue }
            let word = String(cString: wordPtr)

            guard let blob = sqlite3_column_blob(stmt, 1) else { continue }
            let bytes = Int(sqlite3_column_bytes(stmt, 1))
            guard bytes == expectedBytes else { continue }

            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: blob), count: bytes, deallocator: .none)
            if let vec: [Float] = data.withUnsafeBytes({ raw in
                let floats = raw.bindMemory(to: Float.self)
                guard floats.count == dim else { return nil }
                return Array(floats)
            }) {
                out[word] = vec
            }
        }

        return out
    }

    func clearSessionCache() {
        cache.removeAll()
        knownMissingEmbedding.removeAll()
        inFlight.removeAll()
        // Keep allWords cached; it is static and expensive to reload.
    }

    // MARK: - Internals

    private func loadAllWordsIfNeeded() async -> [String] {
        if allWordsLoaded {
            return allWords
        }

        guard let url = Bundle.main.url(forResource: "dictionary", withExtension: "sqlite3") else {
            return []
        }

        let loaded: [String] = await Task.detached(priority: .utility) {
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

            return words
        }.value

        allWords = loaded
        allWordsLoaded = true
        return loaded
    }

    private static func insertNeighborStatic(_ n: Neighbor, into arr: inout [Neighbor], topN: Int) {
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
