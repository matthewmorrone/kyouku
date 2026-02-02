import SwiftUI

struct PasteInlineTokenActionPanel: View {
    let selection: TokenSelectionContext
    let lookup: DictionaryLookupViewModel
    let preferredReading: String?

    let canMergePrevious: Bool
    let canMergeNext: Bool

    let onShowDefinitions: () -> Void
    let onDismiss: () -> Void

    let onSaveWord: (DictionaryEntry) -> Void
    let onApplyReading: (DictionaryEntry) -> Void
    let onApplyCustomReading: (String) -> Void
    let isWordSaved: (DictionaryEntry) -> Bool

    let onMergePrevious: () -> Void
    let onMergeNext: () -> Void
    let onSplit: (Int) -> Void
    let onReset: () -> Void

    let isSelectionCustomized: Bool

    let overrideSignature: Int
    let focusSplitMenu: Bool
    let onSplitFocusConsumed: () -> Void

    let coordinateSpaceName: String

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                TokenActionPanel(
                    selection: selection,
                    lookup: lookup,
                    preferredReading: preferredReading,
                    canMergePrevious: canMergePrevious,
                    canMergeNext: canMergeNext,
                    onShowDefinitions: onShowDefinitions,
                    onDismiss: onDismiss,
                    onSaveWord: onSaveWord,
                    onApplyReading: onApplyReading,
                    onApplyCustomReading: onApplyCustomReading,
                    isWordSaved: isWordSaved,
                    onMergePrevious: onMergePrevious,
                    onMergeNext: onMergeNext,
                    onSplit: onSplit,
                    onReset: onReset,
                    isSelectionCustomized: isSelectionCustomized,
                    enableDragToDismiss: true,
                    embedInMaterialBackground: true,
                    // The inline panel must respect the bottom safe area.
                    // If we let it use the full container height, the action buttons can
                    // end up under the tab bar / home indicator when the panel grows tall.
                    containerHeight: proxy.size.height - proxy.safeAreaInsets.bottom,
                    focusSplitMenu: focusSplitMenu,
                    onSplitFocusConsumed: onSplitFocusConsumed
                )
                // IMPORTANT: do not disable the panel while resolving a new selection.
                // Users must be able to drag-dismiss or tap-dismiss even if the next
                // lookup is still in flight. The panel renders a built-in busy indicator
                // when stale presented content is shown during `.resolving`.
                .id("token-action-panel-\(overrideSignature)")
                .padding(.horizontal, 0)
                .padding(.bottom, 0)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TokenActionPanelFramePreferenceKey.self,
                            value: proxy.frame(in: .named(coordinateSpaceName))
                        )
                    }
                )
            }
        }
        .zIndex(1)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
