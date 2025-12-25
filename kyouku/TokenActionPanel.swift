import SwiftUI
import UIKit

struct TokenActionPanel: View {
    let selection: TokenSelectionContext
    @ObservedObject var lookup: DictionaryLookupViewModel
    let canMergePrevious: Bool
    let canMergeNext: Bool
    let onDismiss: () -> Void
    let onDefine: (DictionaryEntry) -> Void
    let onUseReading: (DictionaryEntry) -> Void
    let onMergePrevious: () -> Void
    let onMergeNext: () -> Void
    let onSplit: (Int) -> Void
    let onReset: () -> Void
    let isSelectionCustomized: Bool
    @State private var highlightedResultIndex = 0
    @GestureState private var dragOffset: CGFloat = 0
    @State private var isSplitMenuVisible = false
    @State private var leftBucketCount = 0
    @State private var dictionaryContentHeight: CGFloat = 0

    private let dismissTranslationThreshold: CGFloat = 80

    var body: some View {
        VStack(spacing: 12) {
            dictionaryScrollContainer

            actionRow
            if isSplitMenuVisible {
                splitMenu
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .onAppear { resetSplitControls() }
        .onChange(of: selection) { _ in
            resetSplitControls()
            highlightedResultIndex = 0
        }
        .onChange(of: lookup.results.count) { _ in
            highlightedResultIndex = 0
        }
        .contentShape(Rectangle())
        .offset(y: max(0, dragOffset))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: dragOffset)
        .highPriorityGesture(dismissGesture)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionIconButton(label: "Merge with previous token", systemImage: "arrow.left.to.line.square", enabled: canMergePrevious, action: onMergePrevious)
            actionIconButton(label: "Merge with next token", systemImage: "arrow.right.to.line.square", enabled: canMergeNext, action: onMergeNext)
            actionIconButton(
                label: "Adjust split",
                systemImage: "scissors",
                enabled: selection.range.length > 1,
                isActive: isSplitMenuVisible,
                action: toggleSplitMenu
            )
            if isSelectionCustomized {
                actionIconButton(label: "Reset overrides", systemImage: "gobackward", enabled: true, action: onReset)
            }
        }
    }

    // private var customizedBadge: some View {
    //     Label("Customized", systemImage: "wand.and.stars")
    //         .font(.caption2)
    //         .padding(.horizontal, 10)
    //         .padding(.vertical, 4)
    //         .background(.ultraThinMaterial, in: Capsule())
    // }

    private func actionIconButton(label: String, systemImage: String, enabled: Bool, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 10))
        .controlSize(.mini)
        .disabled(enabled == false)
        .tint(.accentColor)
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 1.2)
            }
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var dictionaryResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            if lookup.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = lookup.errorMessage, error.isEmpty == false {
                Text(error)
                    .foregroundStyle(.secondary)
            } else if lookup.results.isEmpty {
                Text("No matches for \(selection.surface). Try editing the selection or typing a different term in the Dictionary tab.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .multilineTextAlignment(.leading)
            } else if let highlighted = highlightedEntry {
                HStack(alignment: .center, spacing: 8) {
                    pagerButton(systemImage: "chevron.left", isDisabled: highlighted.index == 0) {
                        goToPreviousResult()
                    }

                    dictionaryCard(
                        for: highlighted.entry,
                        positionText: "\(highlighted.index + 1)/\(lookup.results.count)"
                    )
                    .highPriorityGesture(horizontalSwipeGesture)

                    pagerButton(systemImage: "chevron.right", isDisabled: highlighted.index >= lookup.results.count - 1) {
                        goToNextResult()
                    }
                }
            }
        }
    }

    private func pagerButton(systemImage: String, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 18)
                .padding(.vertical, 48)
        }
        .buttonStyle(.plain)
        .foregroundColor(isDisabled ? Color.secondary.opacity(0.4) : .accentColor)
        .contentShape(Rectangle())
        .disabled(isDisabled)
    }

    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -30 {
                    goToNextResult()
                } else if value.translation.width > 30 {
                    goToPreviousResult()
                }
            }
    }

    private func goToPreviousResult() {
        guard highlightedResultIndex > 0 else { return }
        highlightedResultIndex -= 1
    }

    private func goToNextResult() {
        guard highlightedResultIndex < max(0, lookup.results.count - 1) else { return }
        highlightedResultIndex += 1
    }

    private func dictionaryCard(for entry: DictionaryEntry, positionText: String) -> some View {
        let selectionHasKanji = containsKanji(selection.surface)
        let primaryText: String
        if selectionHasKanji {
            if entry.kanji.isEmpty == false {
                primaryText = entry.kanji
            } else if let kana = entry.kana, kana.isEmpty == false {
                primaryText = kana
            } else {
                primaryText = selection.surface
            }
        } else {
            if let kana = entry.kana, kana.isEmpty == false {
                primaryText = kana
            } else {
                primaryText = selection.surface
            }
        }

        let secondaryText: String? = {
            guard selectionHasKanji else { return nil }
            guard let kana = entry.kana, kana.isEmpty == false else { return nil }
            return kana == primaryText ? nil : kana
        }()

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.headline)
                if let kana = secondaryText {
                    Text(kana)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if entry.gloss.isEmpty == false {
                Text(entry.gloss)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                iconActionButton(
                    systemImage: "character.book.closed.fill",
                    tint: .accentColor,
                    accessibilityLabel: "Apply dictionary reading"
                ) {
                    onUseReading(entry)
                }
                .disabled(canUseReading(entry) == false)

                iconActionButton(
                    systemImage: "bookmark.fill",
                    tint: .secondary,
                    accessibilityLabel: "Save entry to note"
                ) {
                    onDefine(entry)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(alignment: .topTrailing) {
            Text(positionText)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
        }
    }

    private func iconActionButton(systemImage: String, tint: Color, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .accessibilityLabel(accessibilityLabel)
    }

    private var selectionCharacters: [Character] {
        Array(selection.surface)
    }

    private var leftBucketText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let count = max(0, min(leftBucketCount, selectionCharacters.count))
        return String(selectionCharacters.prefix(count))
    }

    private var rightBucketText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let suffixCount = max(0, selectionCharacters.count - leftBucketCount)
        guard suffixCount > 0 else { return "" }
        return String(selectionCharacters.suffix(suffixCount))
    }

    private var applySplitEnabled: Bool {
        selectionCharacters.count > 1 && leftBucketCount > 0 && leftBucketCount < selectionCharacters.count
    }

    private var leftBucketUTF16Length: Int {
        guard applySplitEnabled else { return 0 }
        let prefixString = String(selectionCharacters.prefix(leftBucketCount))
        return prefixString.utf16.count
    }

    private func moveCharacterLeftToRight() {
        guard leftBucketCount > 0 else { return }
        leftBucketCount -= 1
    }

    private func moveCharacterRightToLeft() {
        guard leftBucketCount < selectionCharacters.count else { return }
        leftBucketCount += 1
    }

    private func toggleSplitMenu() {
        guard selectionCharacters.count > 1 else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if isSplitMenuVisible {
                isSplitMenuVisible = false
            } else {
                leftBucketCount = selectionCharacters.count
                isSplitMenuVisible = true
            }
        }
    }

    private func resetSplitControls() {
        leftBucketCount = selectionCharacters.count
        isSplitMenuVisible = false
    }

    @ViewBuilder
    private var splitMenu: some View {
        if selectionCharacters.count > 1 {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    splitBucketButton(
                        text: leftBucketText,
                        alignment: .trailing,
                        isEnabled: leftBucketCount < selectionCharacters.count,
                        action: moveCharacterRightToLeft
                    )

                    Image(systemName: "arrow.left.arrow.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    splitBucketButton(
                        text: rightBucketText,
                        alignment: .leading,
                        isEnabled: leftBucketCount > 0,
                        action: moveCharacterLeftToRight
                    )
                }

                HStack(spacing: 12) {
                    Button("Cancel") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isSplitMenuVisible = false
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Apply") {
                        guard applySplitEnabled else { return }
                        onSplit(leftBucketUTF16Length)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            isSplitMenuVisible = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                    .disabled(applySplitEnabled == false)
                }
                .font(.caption)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func splitBucketButton(text: String, alignment: Alignment, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text.isEmpty ? "—" : text)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: alignment)
                .frame(height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isEnabled ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private var dictionaryScrollContainer: some View {
        let measuredResults = dictionaryResults
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: DictionaryContentHeightPreferenceKey.self, value: proxy.size.height)
                }
            )
            .onPreferenceChange(DictionaryContentHeightPreferenceKey.self) { newValue in
                let clamped = max(0, newValue)
                if abs(dictionaryContentHeight - clamped) > 0.5 {
                    dictionaryContentHeight = clamped
                }
            }

        if let maxHeight = dictionaryScrollMaxHeight, dictionaryContentHeight > maxHeight {
            ScrollView {
                measuredResults
                    .padding(.vertical, 4)
            }
            .frame(maxHeight: maxHeight, alignment: .top)
            .scrollIndicators(.hidden)
        } else {
            measuredResults
        }
    }

    private var dictionaryScrollMaxHeight: CGFloat? {
        let allowance = panelHeightLimit - estimatedChromeHeight
        return allowance > 0 ? allowance : nil
    }

    private var estimatedChromeHeight: CGFloat {
        var height: CGFloat = 12 // spacing
        height += actionRowHeight
        if isSplitMenuVisible {
            height += splitMenuHeight
        }
        return height + 40 // padding + misc
    }

    private var panelHeightLimit: CGFloat {
        min(UIScreen.main.bounds.height * 0.55, 480)
    }

    private var actionRowHeight: CGFloat {
        48
    }

    private var splitMenuHeight: CGFloat {
        190
    }

    private func containsKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private func canUseReading(_ entry: DictionaryEntry) -> Bool {
        let candidate = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty == false
    }

    private var highlightedEntry: (entry: DictionaryEntry, index: Int)? {
        guard lookup.results.isEmpty == false else { return nil }
        let safeIndex = min(highlightedResultIndex, lookup.results.count - 1)
        return (lookup.results[safeIndex], safeIndex)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.height)
            }
            .onEnded { value in
                let translation = value.translation.height
                let predicted = value.predictedEndTranslation.height
                guard translation > dismissTranslationThreshold || predicted > dismissTranslationThreshold else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    onDismiss()
                }
            }
    }
}

private struct DictionaryContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    TokenActionPanel(
        selection: TokenSelectionContext(
            spanIndex: 0,
            range: NSRange(location: 0, length: 2),
            surface: "京都",
            annotatedSpan: AnnotatedSpan(span: TextSpan(range: NSRange(location: 0, length: 2), surface: "京都"), readingKana: "きょうと")
        ),
        lookup: DictionaryLookupViewModel(),
        canMergePrevious: false,
        canMergeNext: true,
        onDismiss: {},
        onDefine: { _ in },
        onUseReading: { _ in },
        onMergePrevious: {},
        onMergeNext: {},
        onSplit: { _ in },
        onReset: {},
        isSelectionCustomized: true
    )
    .padding()
    .background(Color.black.opacity(0.05))
}
