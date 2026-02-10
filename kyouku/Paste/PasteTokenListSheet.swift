import SwiftUI
import Foundation

struct PasteTokenListSheet: View {
    let items: [TokenListItem]
    let noteID: UUID
    let isReady: Bool
    let isEditing: Bool
    let selectedRange: NSRange?

    @Binding var hideDuplicateTokens: Bool
    @Binding var hideCommonParticles: Bool

    let onSelect: (Int) -> Void
    let onGoTo: (Int) -> Void
    let onAdd: (Int) -> Void
    let onAddAll: () -> Void

    let onMergeLeft: (Int) -> Void
    let onMergeRight: (Int) -> Void
    let onSplit: (Int) -> Void

    let canMergeLeft: (Int) -> Bool
    let canMergeRight: (Int) -> Bool

    @Binding var sheetSelection: TokenSelectionContext?
    let dictionaryPanel: (TokenSelectionContext) -> TokenActionPanel

    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ExtractWordsView(
                items: items,
                noteID: noteID,
                isReady: isReady,
                isEditing: isEditing,
                selectedRange: selectedRange,
                hideDuplicateTokens: $hideDuplicateTokens,
                hideCommonParticles: $hideCommonParticles,
                onSelect: onSelect,
                onGoTo: onGoTo,
                onAdd: onAdd,
                onAddAll: onAddAll,
                onMergeLeft: onMergeLeft,
                onMergeRight: onMergeRight,
                onSplit: onSplit,
                canMergeLeft: canMergeLeft,
                canMergeRight: canMergeRight,
                sheetSelection: $sheetSelection,
                dictionaryPanel: dictionaryPanel,
                onDone: onDone
            )
        }
    }
}
