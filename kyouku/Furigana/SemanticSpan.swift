import Foundation

struct SemanticSpan: Equatable, Hashable {
    /// Union range of the member spans (UTF-16 / `NSRange`).
    let range: NSRange
    /// Surface text for `range`.
    let surface: String
    /// Indices of the original spans (contiguous, half-open) that form this unit.
    let sourceSpanIndices: Range<Int>
    /// Optional kana reading (normalized to Hiragana) for the whole semantic unit.
    let readingKana: String?

    init(range: NSRange, surface: String, sourceSpanIndices: Range<Int>, readingKana: String?) {
        self.range = range
        self.surface = surface
        self.sourceSpanIndices = sourceSpanIndices
        self.readingKana = readingKana
    }
}

