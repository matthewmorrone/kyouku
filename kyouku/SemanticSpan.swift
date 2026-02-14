import Foundation

/// Stage 2.5 semantic grouping output.
///
/// A `SemanticSpan` represents a contiguous group of one or more Stage-1 `TextSpan`s
/// that should be treated as a single semantic unit for ruby projection.
///
/// IMPORTANT:
/// - All ranges are `NSRange` in UTF-16 code units.
/// - This does not mutate or replace the original `TextSpan`s.
/// - Grouping decisions are driven by MeCab token coverage, not substring heuristics.
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
