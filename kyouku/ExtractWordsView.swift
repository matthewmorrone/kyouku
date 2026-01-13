import SwiftUI
import Foundation

struct ExtractWordsView: View {
    private struct DictionaryPanelHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    // Inputs mirrored from PasteView's tokenListSheet usage
    let items: [TokenListItem]
    let isReady: Bool
    let isEditing: Bool
    let selectedRange: NSRange?
    @Binding var hideDuplicateTokens: Bool
    @Binding var hideCommonParticles: Bool

    let onSelect: (Int) -> Void
    let onGoTo: (Int) -> Void
    let onAdd: (Int) -> Void
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
        isReady: Bool,
        isEditing: Bool,
        selectedRange: NSRange?,
        hideDuplicateTokens: Binding<Bool>,
        hideCommonParticles: Binding<Bool>,
        onSelect: @escaping (Int) -> Void,
        onGoTo: @escaping (Int) -> Void,
        onAdd: @escaping (Int) -> Void,
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
        self.isReady = isReady
        self.isEditing = isEditing
        self.selectedRange = selectedRange
        self._hideDuplicateTokens = hideDuplicateTokens
        self._hideCommonParticles = hideCommonParticles
        self.onSelect = onSelect
        self.onGoTo = onGoTo
        self.onAdd = onAdd
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
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()

                    HStack(spacing: 10) {
                        Toggle("Hide duplicates", isOn: $hideDuplicateTokens)
                        Toggle("Hide particles", isOn: $hideCommonParticles)
                    }

                    TokenListPanel(
                        items: items,
                        isReady: isReady,
                        isEditing: isEditing,
                        selectedRange: selectedRange,
                        bottomOverscrollHeight: (sheetSelection != nil && dictionaryPanelHeight > 0) ? (dictionaryPanelHeight + 24) : 0,
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
                .padding(.vertical, 12)

                if let selection = sheetSelection {
                    dictionaryPanel(selection)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
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
                    dictionaryPanelHeight = clamped
                }
            }
            .onChange(of: sheetSelection) { _, newValue in
                if newValue == nil {
                    dictionaryPanelHeight = 0
                }
            }
            .navigationTitle("Extract Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDone() }
                }
            }
        }
    }
}

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

struct TokenListPanel: View {
    let items: [TokenListItem]
    let isReady: Bool
    let isEditing: Bool
    let selectedRange: NSRange?
    let bottomOverscrollHeight: CGFloat
    let onSelect: (Int) -> Void
    let onGoTo: (Int) -> Void
    let onAdd: (Int) -> Void
    let onMergeLeft: (Int) -> Void
    let onMergeRight: (Int) -> Void
    let onSplit: (Int) -> Void
    let canMergeLeft: (Int) -> Bool
    let canMergeRight: (Int) -> Bool

    init(
        items: [TokenListItem],
        isReady: Bool,
        isEditing: Bool,
        selectedRange: NSRange?,
        bottomOverscrollHeight: CGFloat = 0,
        onSelect: @escaping (Int) -> Void,
        onGoTo: @escaping (Int) -> Void,
        onAdd: @escaping (Int) -> Void,
        onMergeLeft: @escaping (Int) -> Void,
        onMergeRight: @escaping (Int) -> Void,
        onSplit: @escaping (Int) -> Void,
        canMergeLeft: @escaping (Int) -> Bool,
        canMergeRight: @escaping (Int) -> Bool
    ) {
        self.items = items
        self.isReady = isReady
        self.isEditing = isEditing
        self.selectedRange = selectedRange
        self.bottomOverscrollHeight = bottomOverscrollHeight
        self.onSelect = onSelect
        self.onGoTo = onGoTo
        self.onAdd = onAdd
        self.onMergeLeft = onMergeLeft
        self.onMergeRight = onMergeRight
        self.onSplit = onSplit
        self.canMergeLeft = canMergeLeft
        self.canMergeRight = canMergeRight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Spacer()
                if isReady == false, isEditing == false {
                    ProgressView()
                        .scaleEffect(0.75)
                }
            }

            if isEditing {
                Text("Tokens appear after exiting edit mode.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if items.isEmpty {
                Text(isReady ? "No tokens detected." : "Tokenizing…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            TokenListRow(
                                item: item,
                                isSelected: isItemSelected(item),
                                onSelect: { onSelect(item.spanIndex) },
                                onGoTo: { onGoTo(item.spanIndex) },
                                onAdd: { onAdd(item.spanIndex) },
                                onMergeLeft: { onMergeLeft(item.spanIndex) },
                                onMergeRight: { onMergeRight(item.spanIndex) },
                                onSplit: { onSplit(item.spanIndex) },
                                mergeLeftEnabled: canMergeLeft(item.spanIndex),
                                mergeRightEnabled: canMergeRight(item.spanIndex)
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, max(0, bottomOverscrollHeight))
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isItemSelected(_ item: TokenListItem) -> Bool {
        guard let range = selectedRange else { return false }
        return range.location == item.range.location && range.length == item.range.length
    }

    private struct TokenListRow: View {
        let item: TokenListItem
        let isSelected: Bool
        let onSelect: () -> Void
        let onGoTo: () -> Void
        let onAdd: () -> Void
        let onMergeLeft: () -> Void
        let onMergeRight: () -> Void
        let onSplit: () -> Void
        let mergeLeftEnabled: Bool
        let mergeRightEnabled: Bool

        var body: some View {
            HStack(spacing: 12) {
                Button(action: onSelect) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.surface)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let reading = readingText {
                                Text(reading)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onAdd) {
                    if item.isAlreadySaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "star.circle")
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(8)
                .font(.title3)
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(item.isAlreadySaved ? "Remove from saved" : "Save")
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            )
            .contentShape(Rectangle())
            .contextMenu {
                Button(action: onGoTo) {
                    Label("Go to in Note", systemImage: "text.magnifyingglass")
                }

                Button(action: onMergeLeft) {
                    Label("Merge Left", systemImage: "arrow.left.to.line")
                }
                .disabled(mergeLeftEnabled == false)

                Button(action: onMergeRight) {
                    Label("Merge Right", systemImage: "arrow.right.to.line")
                }
                .disabled(mergeRightEnabled == false)

                Button(action: onSplit) {
                    Label("Split", systemImage: "scissors")
                }
                .disabled(item.canSplit == false)
            }
        }

        private var readingText: String? {
            guard let reading = item.displayReading?.trimmingCharacters(in: .whitespacesAndNewlines), reading.isEmpty == false else { return nil }
            if Self.isKanaOnly(item.surface) {
                return nil
            }
            return reading
        }

        private static func isKanaOnly(_ text: String) -> Bool {
            let scalars = text.unicodeScalars
            guard scalars.isEmpty == false else { return false }
            return scalars.allSatisfy { scalar in
                isHiragana(scalar) || isKatakana(scalar)
            }
        }

        private static func isHiragana(_ scalar: UnicodeScalar) -> Bool {
            (0x3040...0x309F).contains(Int(scalar.value))
        }

        private static func isKatakana(_ scalar: UnicodeScalar) -> Bool {
            (0x30A0...0x30FF).contains(Int(scalar.value)) || Int(scalar.value) == 0xFF70
        }
    }
}

