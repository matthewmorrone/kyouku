import Foundation

enum DebugDictionaryHighlighting {
    /// Int coverage level (>= 1) indicating how many overlapping dictionary matches include this range.
    ///
    /// This is used for debug visualization (e.g. “highlight all dictionary entries”).
    static let coverageLevelAttribute = NSAttributedString.Key("DebugDictionaryCoverageLevel")
}
