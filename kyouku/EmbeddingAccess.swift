import Foundation

/// High-level access layer for embeddings.
///
/// - Uses batch SQLite queries.
/// - Thread-safe.
/// - Session-level LRU cache.
final class EmbeddingAccess: @unchecked Sendable {
    struct Configuration {
        var cacheSize: Int
        var poolSize: Int
        var maxBatchSize: Int

        init(cacheSize: Int = 2048, poolSize: Int = max(1, ProcessInfo.processInfo.activeProcessorCount), maxBatchSize: Int = 200) {
            self.cacheSize = max(0, cacheSize)
            self.poolSize = max(1, poolSize)
            self.maxBatchSize = max(1, maxBatchSize)
        }
    }

    static let shared = EmbeddingAccess()

    private let cache: EmbeddingLRUCache<String, [Float]>
    private let reader: EmbeddingsSQLiteBatchReader

    init(config: Configuration = Configuration()) {
        self.cache = EmbeddingLRUCache<String, [Float]>(capacity: config.cacheSize)
        self.reader = EmbeddingsSQLiteBatchReader(
            config: .init(poolSize: config.poolSize, maxBatchSize: config.maxBatchSize)
        )
    }

    /// Batch fetch vectors for provided words.
    ///
    /// Missing embeddings are omitted.
    func vectors(for words: [String]) -> [String: [Float]] {
        guard words.isEmpty == false else { return [:] }

        var result: [String: [Float]] = [:]
        result.reserveCapacity(words.count)

        var toFetch: [String] = []
        toFetch.reserveCapacity(words.count)

        for w in words {
            if let cached = cache.get(w) {
                #if DEBUG
                EmbeddingDiagnostics.shared.recordCacheHit()
                #endif
                result[w] = cached
            } else {
                #if DEBUG
                EmbeddingDiagnostics.shared.recordCacheMiss()
                #endif
                toFetch.append(w)
            }
        }

        guard toFetch.isEmpty == false else { return result }

        do {
            let fetched = try reader.fetchVectors(for: toFetch)
            for (k, v) in fetched {
                cache.set(k, v)
                result[k] = v
                #if DEBUG
                EmbeddingDiagnostics.shared.recordLookupHit()
                #endif
            }
            #if DEBUG
            if fetched.count < toFetch.count {
                for _ in 0..<(toFetch.count - fetched.count) {
                    EmbeddingDiagnostics.shared.recordLookupMiss()
                }
            }
            #endif
        } catch {
            // Graceful failure: return whatever the cache provided.
        }

        return result
    }
}
