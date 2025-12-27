import Foundation

struct TokenSelectionContext: Equatable, Identifiable {
    let spanIndex: Int
    let range: NSRange
    let surface: String
    let annotatedSpan: AnnotatedSpan

    var id: String { "\(spanIndex)-\(range.location)-\(range.length)" }
}
