import Foundation

struct SelectionSpanCandidate: Hashable {
    let range: NSRange
    let displayKey: String
    let lookupKey: String
}