import Foundation
import CoreGraphics

extension Notification.Name {
    static let kyoukuSplitPaneScrollSync = Notification.Name("kyouku.splitPane.scrollSync")
}

@MainActor
enum SplitPaneScrollSyncStore {
    struct Snapshot {
        let source: String
        let fx: CGFloat
        let fy: CGFloat
        let ox: CGFloat
        let oy: CGFloat
        let sx: CGFloat
        let sy: CGFloat
        let timestamp: CFTimeInterval
    }

    private static var latestByGroup: [String: Snapshot] = [:]

    static func record(group: String, snapshot: Snapshot) {
        latestByGroup[group] = snapshot
    }

    static func latest(group: String) -> Snapshot? {
        latestByGroup[group]
    }
}

extension NSAttributedString.Key {
    static let furiganaAnnotation = NSAttributedString.Key("RubyAnnotation")
    static let furiganaReadingText = NSAttributedString.Key("RubyReadingText")
    static let furiganaReadingFontSize = NSAttributedString.Key("RubyReadingFontSize")
}

enum FuriganaAnnotationVisibility {
    case visible
    case hiddenKeepMetrics
    case removed
}

enum FuriganaHorizontalAlignment {
    case center
    case leading
}

struct FuriganaSpanSelection {
    let tokenIndex: Int
    let semanticSpan: SemanticSpan
    let highlightRange: NSRange
}

enum FuriganaContextMenuAction {
    case mergeLeft
    case mergeRight
    case split
}
