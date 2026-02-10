import Foundation

/// A single session object that combines feature flags + gating + access.
///
/// This is structural glue only; no UI wiring.
final class EmbeddingAccessSession: @unchecked Sendable {
    let access: EmbeddingAccess
    var flags: EmbeddingFeatureFlags

    init(access: EmbeddingAccess = .shared, flags: EmbeddingFeatureFlags = .default) {
        self.access = access
        self.flags = flags
        EmbeddingFeatureGates.shared.ensureMetadataChecked()
    }

    func isFeatureEnabled(_ feature: EmbeddingFeature) -> Bool {
        EmbeddingFeatureGates.shared.ensureMetadataChecked()
        guard EmbeddingFeatureGates.shared.isEnabled(feature) else { return false }

        switch feature {
        case .semanticSearch:
            return flags.semanticSearch
        case .similarWords:
            return flags.similarWords
        case .flashcardAdaptation:
            return flags.flashcardAdaptation
        case .tokenBoundaryResolution:
            return flags.tokenBoundaryResolution
        }
    }
}
