import SwiftUI
import Foundation

struct TokenListItem: Identifiable {
    let spanIndex: Int
    let range: NSRange
    let surface: String
    let reading: String?
    let displayReading: String?
    let isAlreadySaved: Bool

    var id: Int { spanIndex }
    var canSplit: Bool { range.length > 1 }
}

