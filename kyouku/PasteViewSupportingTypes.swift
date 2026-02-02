import SwiftUI
import Foundation

// MARK: - Geometry Preferences (PasteView)

struct TokenActionPanelFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

struct PasteAreaFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

struct SheetPanelHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum MergeDirection {
    case previous
    case next
}

final class OverrideUndoToken: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func perform() {
        action()
    }
}

struct ControlCell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }
}

// MARK: - Incremental Lookup (PasteView)

struct IncrementalLookupHit: Identifiable, Hashable {
    let matchedSurface: String
    let entry: DictionaryEntry

    var id: String { "\(matchedSurface)#\(entry.id)" }
}

struct IncrementalLookupCollapsed: Identifiable, Hashable {
    let matchedSurface: String
    let kanji: String
    let gloss: String
    let kanaList: String?
    let entries: [DictionaryEntry]

    var id: String {
        let k = kanji.isEmpty ? "(no-kanji)" : kanji
        return "\(matchedSurface)#\(k)#\(gloss)"
    }
}

struct IncrementalLookupGroup: Identifiable, Hashable {
    let matchedSurface: String
    let pages: [IncrementalLookupCollapsed]

    var id: String { matchedSurface }
}
