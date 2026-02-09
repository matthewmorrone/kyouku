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
    let noteID: UUID
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

    @EnvironmentObject private var readingOverrides: ReadingOverridesStore

    init(
        items: [TokenListItem],
        noteID: UUID,
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
        self.noteID = noteID
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
                let noteOverrides = readingOverrides.overrides(for: noteID)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            TokenListRow(
                                item: item,
                                noteID: noteID,
                                noteOverrides: noteOverrides,
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

                        // Add explicit bottom space so the pinned dictionary panel doesn't
                        // cover the last rows.
                        if bottomOverscrollHeight > 0 {
                            Color.clear
                                .frame(height: bottomOverscrollHeight)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func isItemSelected(_ item: TokenListItem) -> Bool {
        guard let range = selectedRange else { return false }
        return range.location == item.range.location && range.length == item.range.length
    }

    private struct TokenListRow: View {
        let item: TokenListItem
        let noteID: UUID
        let noteOverrides: [ReadingOverride]
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Allow tap-to-select while still supporting long-press text selection.
                .onTapGesture(perform: onSelect)
                .textSelection(.enabled)

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
            if Self.isKanaOnly(item.surface) {
                return nil
            }

            let fallback = item.reading ?? item.displayReading
            let preferred = preferredReading(for: item.range, fallback: fallback)
            guard let display = readingWithOkurigana(surface: item.surface, baseReading: preferred)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  display.isEmpty == false
            else {
                return nil
            }
            return display
        }

        private func preferredReading(for range: NSRange, fallback: String?) -> String? {
            let overrides = noteOverrides.filter { $0.overlaps(range) }
            if let exact = overrides.first(where: {
                $0.rangeStart == range.location &&
                $0.rangeLength == range.length &&
                $0.userKana != nil
            }) {
                return exact.userKana
            }

            if let bestOverlap = overrides
                .filter({ $0.userKana != nil })
                .max(by: { lhs, rhs in
                    let lhsRange = NSRange(location: lhs.rangeStart, length: lhs.rangeLength)
                    let rhsRange = NSRange(location: rhs.rangeStart, length: rhs.rangeLength)
                    return NSIntersectionRange(lhsRange, range).length < NSIntersectionRange(rhsRange, range).length
                }) {
                return bestOverlap.userKana
            }

            return fallback
        }

        private func readingWithOkurigana(surface: String, baseReading: String?) -> String? {
            guard var reading = baseReading?.trimmingCharacters(in: .whitespacesAndNewlines), reading.isEmpty == false else { return nil }
            guard let suffix = trailingKanaSuffix(in: surface), suffix.isEmpty == false else { return reading }
            if reading.hasSuffix(suffix) {
                return reading
            }
            reading.append(suffix)
            return reading
        }

        private func trailingKanaSuffix(in surface: String) -> String? {
            guard surface.isEmpty == false else { return nil }
            var scalars: [UnicodeScalar] = []
            for scalar in surface.unicodeScalars.reversed() {
                if isKanaScalar(scalar) {
                    scalars.append(scalar)
                } else {
                    break
                }
            }
            guard scalars.isEmpty == false else { return nil }
            return String(String.UnicodeScalarView(scalars.reversed()))
        }

        private func isKanaScalar(_ scalar: UnicodeScalar) -> Bool {
            (0x3040...0x309F).contains(scalar.value) ||
            (0x30A0...0x30FF).contains(scalar.value) ||
            scalar.value == 0xFF70 ||
            (0xFF66...0xFF9F).contains(scalar.value)
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
