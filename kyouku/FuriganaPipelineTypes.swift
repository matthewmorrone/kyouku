import Foundation

/// Stage 1 segmentation output. Represents a bounded span derived from the
/// in-memory JMdict trie. No readings, dictionary entries, or semantic weight
/// leak beyond this boundary.
struct TextSpan: Equatable, Hashable {
    let range: NSRange
    let surface: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(range.location)
        hasher.combine(range.length)
        hasher.combine(surface)
    }

    static func == (lhs: TextSpan, rhs: TextSpan) -> Bool {
        lhs.range.location == rhs.range.location &&
        lhs.range.length == rhs.range.length &&
        lhs.surface == rhs.surface
    }
}

/// Stage 2 reading attachment output. Each span now carries its optional kana
/// reading (normalized to Hiragana). No other metadata survives into later
/// stages, keeping reading attachment isolated.
struct AnnotatedSpan: Equatable, Hashable {
    let span: TextSpan
    let readingKana: String?
    let lemmaCandidates: [String]

    init(span: TextSpan, readingKana: String?, lemmaCandidates: [String] = []) {
        self.span = span
        self.readingKana = readingKana
        self.lemmaCandidates = lemmaCandidates
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(span)
        hasher.combine(readingKana ?? "")
        hasher.combine(lemmaCandidates.count)
        for lemma in lemmaCandidates {
            hasher.combine(lemma)
        }
    }
}
