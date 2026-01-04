import Foundation

struct TokenSelectionContext: Equatable, Identifiable {
    /// Index into the current Stage-2 semantic spans.
    let tokenIndex: Int
    let range: NSRange
    let surface: String
    let semanticSpan: SemanticSpan
    /// Indices into the current Stage-1 annotated spans that this semantic token covers.
    let sourceSpanIndices: Range<Int>
    /// Aggregated stage-1 metadata for downstream dictionary/UX flows.
    let annotatedSpan: AnnotatedSpan

    var id: String { "\(tokenIndex)-\(range.location)-\(range.length)" }
}
