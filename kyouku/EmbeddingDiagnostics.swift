import Foundation

#if DEBUG
final class EmbeddingDiagnostics: @unchecked Sendable {
    static let shared = EmbeddingDiagnostics()

    struct Snapshot {
        var lookupHits: Int
        var lookupMisses: Int
        var fallbackUsed: Int
        var cacheHits: Int
        var cacheMisses: Int
    }

    private struct State {
        var lookupHits: Int = 0
        var lookupMisses: Int = 0
        var fallbackUsed: Int = 0
        var cacheHits: Int = 0
        var cacheMisses: Int = 0
    }

    private let lock = NSLock()
    private var state = State()

    func recordLookupHit() { lock.lock(); state.lookupHits += 1; lock.unlock() }
    func recordLookupMiss() { lock.lock(); state.lookupMisses += 1; lock.unlock() }
    func recordFallbackUsed() { lock.lock(); state.fallbackUsed += 1; lock.unlock() }
    func recordCacheHit() { lock.lock(); state.cacheHits += 1; lock.unlock() }
    func recordCacheMiss() { lock.lock(); state.cacheMisses += 1; lock.unlock() }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            lookupHits: state.lookupHits,
            lookupMisses: state.lookupMisses,
            fallbackUsed: state.fallbackUsed,
            cacheHits: state.cacheHits,
            cacheMisses: state.cacheMisses
        )
    }
}
#endif
