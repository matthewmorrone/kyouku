import Foundation

/// Debug-only attribute key used to visualize overlapping dictionary coverage.
///
/// Value is expected to be an `Int` (coverage/overlap count).
enum DebugDictionaryHighlighting {
	static let coverageLevelAttribute = NSAttributedString.Key("kyouku.debug.dictionaryCoverageLevel")
}

