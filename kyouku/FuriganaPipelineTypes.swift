import Foundation

/// Stage 1 segmentation output. Represents a bounded span derived from the
/// in-memory JMdict trie. No readings, dictionary entries, or semantic weight
/// leak beyond this boundary.
struct TextSpan: Equatable, Hashable {
    let range: NSRange
    let surface: String
    /// True when the span boundary came from a JMdict surface-form trie match.
    /// This is intentionally independent from MeCab/IPADic coverage.
    var isLexiconMatch: Bool = false

    func hash(into hasher: inout Hasher) {
        hasher.combine(range.location)
        hasher.combine(range.length)
        hasher.combine(surface)
        hasher.combine(isLexiconMatch)
    }

    static func == (lhs: TextSpan, rhs: TextSpan) -> Bool {
        lhs.range.location == rhs.range.location &&
        lhs.range.length == rhs.range.length &&
        lhs.surface == rhs.surface &&
        lhs.isLexiconMatch == rhs.isLexiconMatch
    }
}

extension TextSpan {
    static func describe(spans: [TextSpan]) -> String {
        spans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
    }
}

/// Stage 2 reading attachment output. Each span now carries its optional kana
/// reading (normalized to Hiragana). No other metadata survives into later
/// stages, keeping reading attachment isolated.
struct AnnotatedSpan: Equatable, Hashable {
    let span: TextSpan
    let readingKana: String?
    let lemmaCandidates: [String]
    let partOfSpeech: String?

    init(span: TextSpan, readingKana: String?, lemmaCandidates: [String] = [], partOfSpeech: String? = nil) {
        self.span = span
        self.readingKana = readingKana
        self.lemmaCandidates = lemmaCandidates
        self.partOfSpeech = partOfSpeech
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(span)
        hasher.combine(readingKana ?? "")
        hasher.combine(lemmaCandidates.count)
        for lemma in lemmaCandidates {
            hasher.combine(lemma)
        }
        hasher.combine(partOfSpeech ?? "")
    }
}

/// Stage 2.5 semantic grouping output.
///
/// A `SemanticSpan` represents a contiguous group of one or more Stage-1 `TextSpan`s
/// that should be treated as a single semantic unit for ruby projection.
///
/// IMPORTANT:
/// - This does not mutate or replace the original `TextSpan`s.
/// - It exists explicitly downstream of Stage 1 because Stage 1 is lexicon-only.
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
