import SwiftUI
import Foundation

struct ExtractWordsView: View {
    @AppStorage("extractPropagateTokenEdits") private var propagateTokenEdits: Bool = false

    private struct DictionaryPanelHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    // Inputs mirrored from PasteView's tokenListSheet usage
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

    @State private var dictionaryPanelHeight: CGFloat = 0

    init(
        items: [TokenListItem],
        noteID: UUID,
        isReady: Bool,
        isEditing: Bool,
        selectedRange: NSRange?,
        hideDuplicateTokens: Binding<Bool>,
        hideCommonParticles: Binding<Bool>,
        onSelect: @escaping (Int) -> Void,
        onGoTo: @escaping (Int) -> Void,
        onAdd: @escaping (Int) -> Void,
        onAddAll: @escaping () -> Void,
        onMergeLeft: @escaping (Int) -> Void,
        onMergeRight: @escaping (Int) -> Void,
        onSplit: @escaping (Int) -> Void,
        canMergeLeft: @escaping (Int) -> Bool,
        canMergeRight: @escaping (Int) -> Bool,
        sheetSelection: Binding<TokenSelectionContext?>,
        dictionaryPanel: @escaping (TokenSelectionContext) -> TokenActionPanel,
        onDone: @escaping () -> Void
    ) {
        self.items = items
        self.noteID = noteID
        self.isReady = isReady
        self.isEditing = isEditing
        self.selectedRange = selectedRange
        self._hideDuplicateTokens = hideDuplicateTokens
        self._hideCommonParticles = hideCommonParticles
        self.onSelect = onSelect
        self.onGoTo = onGoTo
        self.onAdd = onAdd
        self.onAddAll = onAddAll
        self.onMergeLeft = onMergeLeft
        self.onMergeRight = onMergeRight
        self.onSplit = onSplit
        self.canMergeLeft = canMergeLeft
        self.canMergeRight = canMergeRight
        self._sheetSelection = sheetSelection
        self.dictionaryPanel = dictionaryPanel
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            let dictionaryPanelBottomPadding: CGFloat = 12
            ZStack(alignment: .bottom) {
                if sheetSelection != nil {
                    // Visual separation: keep the dictionary panel distinct from the list behind.
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.00),
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Button {
                            onAddAll()
                        } label: {
                            Label("Add All", systemImage: "star.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        .font(.subheadline)
                        Spacer()

                        Toggle("Apply edits to all", isOn: $propagateTokenEdits)
                            .labelsHidden()
                            .font(.subheadline)
                            .toggleStyle(.switch)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Toggle("Hide duplicates", isOn: $hideDuplicateTokens)
                        Toggle("Hide particles", isOn: $hideCommonParticles)
                    }

                    TokenListPanel(
                        items: items,
                        noteID: noteID,
                        isReady: isReady,
                        isEditing: isEditing,
                        selectedRange: selectedRange,
                        bottomOverscrollHeight: (sheetSelection != nil && dictionaryPanelHeight > 0) ? (dictionaryPanelHeight + dictionaryPanelBottomPadding) : 0,
                        onSelect: onSelect,
                        onGoTo: onGoTo,
                        onAdd: onAdd,
                        onMergeLeft: onMergeLeft,
                        onMergeRight: onMergeRight,
                        onSplit: onSplit,
                        canMergeLeft: canMergeLeft,
                        canMergeRight: canMergeRight
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if let selection = sheetSelection {
                    dictionaryPanel(selection)
                        .padding(.bottom, dictionaryPanelBottomPadding)
                        .background(
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(key: DictionaryPanelHeightPreferenceKey.self, value: proxy.size.height)
                            }
                        )
                        .zIndex(1)
                }
            }
            .onPreferenceChange(DictionaryPanelHeightPreferenceKey.self) { newValue in
                let clamped = max(0, newValue)
                if abs(dictionaryPanelHeight - clamped) > 0.5 {
                    // Avoid AttributeGraph cycles by deferring measurement-driven state writes.
                    DispatchQueue.main.async {
                        dictionaryPanelHeight = clamped
                    }
                }
            }
            .onChange(of: sheetSelection) { _, newValue in
                if newValue == nil {
                    dictionaryPanelHeight = 0
                }
            }
            .navigationTitle("Extract Words")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

