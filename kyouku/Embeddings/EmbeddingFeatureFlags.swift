import Foundation

/// User-facing feature flags (utilities only; no UI wiring here).
struct EmbeddingFeatureFlags {
    var semanticSearch: Bool = true
    var similarWords: Bool = true
    var flashcardAdaptation: Bool = true
    var tokenBoundaryResolution: Bool = true

    static let `default` = EmbeddingFeatureFlags()
}
