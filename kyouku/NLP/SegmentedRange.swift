import Foundation
import OSLog

struct SegmentedRange: Sendable {
    let range: NSRange
    let isLexiconMatch: Bool
}

