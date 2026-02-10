import Foundation

#if DEBUG
final class EmbeddingDiagnostics: @unchecked Sendable {
    static let shared = EmbeddingDiagnostics()

    private struct State {
        var lookupHits: Int = 0
        var lookupMisses: Int = 0
        var cacheHits: Int = 0
        var cacheMisses: Int = 0
    }

    private let lock = NSLock()
    private var state = State()

    func recordLookupHit() { lock.lock(); state.lookupHits += 1; lock.unlock() }
    func recordLookupMiss() { lock.lock(); state.lookupMisses += 1; lock.unlock() }
    func recordCacheHit() { lock.lock(); state.cacheHits += 1; lock.unlock() }
    func recordCacheMiss() { lock.lock(); state.cacheMisses += 1; lock.unlock() }
}
#endif
