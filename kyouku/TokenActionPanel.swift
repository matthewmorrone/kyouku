import SwiftUI
import UIKit

struct TokenActionPanel: View {
    let selection: TokenSelectionContext
    @ObservedObject var lookup: DictionaryLookupViewModel
    let preferredReading: String?
    let canMergePrevious: Bool
    let canMergeNext: Bool
    let onShowDefinitions: (() -> Void)?
    let onDismiss: () -> Void
    let onSaveWord: (DictionaryEntry) -> Void
    let onApplyReading: (DictionaryEntry) -> Void
    let onApplyCustomReading: ((String) -> Void)?
    let isWordSaved: ((DictionaryEntry) -> Bool)?
    let onMergePrevious: () -> Void
    let onMergeNext: () -> Void
    let onSplit: (Int) -> Void
    let onReset: () -> Void
    let isSelectionCustomized: Bool
    let enableDragToDismiss: Bool
    let embedInMaterialBackground: Bool
    let focusSplitMenu: Bool
    let onSplitFocusConsumed: () -> Void
    @State private var highlightedResultIndex = 0
    @GestureState private var dragOffset: CGFloat = 0
    @State private var isSplitMenuVisible = false
    @State private var leftBucketCount = 0
    @State private var dictionaryContentHeight: CGFloat = 0

    private let dismissTranslationThreshold: CGFloat = 80

    init(
        selection: TokenSelectionContext,
        lookup: DictionaryLookupViewModel,
        preferredReading: String?,
        canMergePrevious: Bool,
        canMergeNext: Bool,
        onShowDefinitions: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        onSaveWord: @escaping (DictionaryEntry) -> Void,
        onApplyReading: @escaping (DictionaryEntry) -> Void,
        onApplyCustomReading: ((String) -> Void)? = nil,
        isWordSaved: ((DictionaryEntry) -> Bool)? = nil,
        onMergePrevious: @escaping () -> Void,
        onMergeNext: @escaping () -> Void,
        onSplit: @escaping (Int) -> Void,
        onReset: @escaping () -> Void,
        isSelectionCustomized: Bool,
        enableDragToDismiss: Bool,
        embedInMaterialBackground: Bool,
        focusSplitMenu: Bool = false,
        onSplitFocusConsumed: @escaping () -> Void = {}
    ) {
        self.selection = selection
        self._lookup = ObservedObject(initialValue: lookup)
        self.preferredReading = preferredReading
        self.canMergePrevious = canMergePrevious
        self.canMergeNext = canMergeNext
        self.onShowDefinitions = onShowDefinitions
        self.onDismiss = onDismiss
        self.onSaveWord = onSaveWord
        self.onApplyReading = onApplyReading
        self.onApplyCustomReading = onApplyCustomReading
        self.isWordSaved = isWordSaved
        self.onMergePrevious = onMergePrevious
        self.onMergeNext = onMergeNext
        self.onSplit = onSplit
        self.onReset = onReset
        self.isSelectionCustomized = isSelectionCustomized
        self.enableDragToDismiss = enableDragToDismiss
        self.embedInMaterialBackground = embedInMaterialBackground
        self.focusSplitMenu = focusSplitMenu
        self.onSplitFocusConsumed = onSplitFocusConsumed
    }

    @ViewBuilder
    var body: some View {
        if enableDragToDismiss {
            panelContent.highPriorityGesture(dismissGesture)
        } else {
            panelContent
        }
    }

    private var panelContent: some View {
        Group {
            if embedInMaterialBackground {
                panelSurface
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            } else {
                panelSurface
            }
        }
    }

    private var panelSurface: some View {
        VStack(spacing: 12) {
            dictionaryScrollContainer

            actionRow
            if isSplitMenuVisible {
                SplitMenuView(
                    selectionCharacters: selectionCharacters,
                    leftBucketCount: $leftBucketCount,
                    onCancel: { closeSplitMenu(animated: true) },
                    onApply: { offset in
                        onSplit(offset)
                        closeSplitMenu(animated: true)
                    }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .onAppear {
            resetSplitControls()
            resetHighlightedResult()
            focusSplitMenuIfNeeded(focusSplitMenu)
        }
        .onChange(of: selection) { _, _ in
            resetSplitControls()
            resetHighlightedResult()
        }
        .onChange(of: lookup.results) { _, _ in
            resetHighlightedResult()
        }
        .onChange(of: focusSplitMenu) { _, newValue in
            focusSplitMenuIfNeeded(newValue)
        }
        .contentShape(Rectangle())
        .offset(y: max(0, dragOffset))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: dragOffset)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionIconButton(label: "Merge with previous token", systemImage: "arrow.left.to.line.square", enabled: canMergePrevious, action: onMergePrevious)
            actionIconButton(label: "Merge with next token", systemImage: "arrow.right.to.line.square", enabled: canMergeNext, action: onMergeNext)
            if let onShowDefinitions {
                actionIconButton(label: "Show all definitions", systemImage: "book", enabled: true, action: onShowDefinitions)
            }
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

    private var selectionCharacters: [Character] {
        Array(selection.surface)
    }

    private func toggleSplitMenu() {
        guard selectionCharacters.count > 1 else { return }
        if handleTwoCharacterSplitIfNeeded() {
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if isSplitMenuVisible {
                isSplitMenuVisible = false
            } else {
                leftBucketCount = selectionCharacters.count
                isSplitMenuVisible = true
            }
        }
    }

    private func focusSplitMenuIfNeeded(_ shouldFocus: Bool) {
        guard shouldFocus else { return }
        defer { onSplitFocusConsumed() }
        guard selectionCharacters.count > 1 else { return }
        if handleTwoCharacterSplitIfNeeded() {
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            leftBucketCount = selectionCharacters.count
            isSplitMenuVisible = true
        }
    }

    private func resetSplitControls() {
        leftBucketCount = selectionCharacters.count
        isSplitMenuVisible = false
    }

    private func handleTwoCharacterSplitIfNeeded() -> Bool {
        guard selectionCharacters.count == 2 else { return false }
        let offset = utf16LengthOfFirstCharacter()
        guard offset > 0 else { return false }
        onSplit(offset)
        return true
    }

    private func utf16LengthOfFirstCharacter() -> Int {
        guard let first = selectionCharacters.first else { return 0 }
        return String(first).utf16.count
    }

    private func closeSplitMenu(animated: Bool) {
        let animations = {
            leftBucketCount = selectionCharacters.count
            isSplitMenuVisible = false
        }
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85), animations)
        } else {
            animations()
        }
    }

    private func resetHighlightedResult() {
        if let preferred = preferredResultIndex() {
            highlightedResultIndex = preferred
        } else {
            highlightedResultIndex = 0
        }
    }

    private func preferredResultIndex() -> Int? {
        guard let raw = preferredReading?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else { return nil }
        return lookup.results.firstIndex { entry in
            let candidate = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate == raw
        }
    }

    @ViewBuilder
    private var dictionaryScrollContainer: some View {
        let measuredResults = LookupResultsView(
            lookup: lookup,
            selection: selection,
            preferredReading: preferredReading,
            highlightedResultIndex: $highlightedResultIndex,
            onApplyReading: onApplyReading,
            onApplyCustomReading: onApplyCustomReading,
            onSaveWord: onSaveWord,
            isWordSaved: isWordSaved
        )
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
        return height + 24 // padding + misc
    }

    private var panelHeightLimit: CGFloat {
        min(currentScreenHeight() * 0.7, 560)
    }

    private func currentScreenHeight() -> CGFloat {
        if let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen {
            return screen.bounds.height
        }
        return 480 // sensible fallback
    }

    private var actionRowHeight: CGFloat {
        48
    }

    private var splitMenuHeight: CGFloat {
        190
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

private struct SplitMenuView: View {
    let selectionCharacters: [Character]
    @Binding var leftBucketCount: Int
    let onCancel: () -> Void
    let onApply: (Int) -> Void

    private var canSplit: Bool {
        selectionCharacters.count > 1 && leftBucketCount > 0 && leftBucketCount < selectionCharacters.count
    }

    private var leftText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let count = max(0, min(leftBucketCount, selectionCharacters.count))
        return String(selectionCharacters.prefix(count))
    }

    private var rightText: String {
        guard selectionCharacters.isEmpty == false else { return "" }
        let suffixCount = max(0, selectionCharacters.count - leftBucketCount)
        guard suffixCount > 0 else { return "" }
        return String(selectionCharacters.suffix(suffixCount))
    }

    private var leftUTF16Length: Int {
        guard canSplit else { return 0 }
        let prefixString = String(selectionCharacters.prefix(leftBucketCount))
        return prefixString.utf16.count
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                bucketButton(text: leftText, alignment: .trailing, isEnabled: leftBucketCount < selectionCharacters.count) {
                    moveCharacterRightToLeft()
                }

                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                bucketButton(text: rightText, alignment: .leading, isEnabled: leftBucketCount > 0) {
                    moveCharacterLeftToRight()
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)

                Button("Apply") {
                    guard canSplit else { return }
                    onApply(leftUTF16Length)
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(canSplit == false)
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

    private func bucketButton(text: String, alignment: Alignment, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text.isEmpty ? "" : text)
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

    private func moveCharacterLeftToRight() {
        guard leftBucketCount > 0 else { return }
        leftBucketCount -= 1
    }

    private func moveCharacterRightToLeft() {
        guard leftBucketCount < selectionCharacters.count else { return }
        leftBucketCount += 1
    }
}

private struct LookupResultsView: View {
    @ObservedObject var lookup: DictionaryLookupViewModel
    let selection: TokenSelectionContext
    let preferredReading: String?
    @Binding var highlightedResultIndex: Int
    let onApplyReading: (DictionaryEntry) -> Void
    let onApplyCustomReading: ((String) -> Void)?
    let onSaveWord: (DictionaryEntry) -> Void
    let isWordSaved: ((DictionaryEntry) -> Bool)?

    @State private var isCustomReadingPromptPresented = false
    @State private var customReadingText = ""

    var body: some View {
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
                HStack(alignment: .center, spacing: 0) {
                    pagerButton(systemImage: "chevron.left", isDisabled: highlighted.index == 0) {
                        goToPreviousResult()
                    }

                    dictionaryCard(
                        entry: highlighted.entry,
                        positionText: "\(highlighted.index + 1)/\(lookup.results.count)"
                    )
                    .highPriorityGesture(horizontalSwipeGesture)

                    pagerButton(systemImage: "chevron.right", isDisabled: highlighted.index >= lookup.results.count - 1) {
                        goToNextResult()
                    }
                }
            }
        }
        .alert("Custom reading", isPresented: $isCustomReadingPromptPresented) {
            TextField("", text: $customReadingText)
            Button("Cancel", role: .cancel) {
                customReadingText = ""
            }
            Button("Apply") {
                let trimmed = customReadingText.trimmingCharacters(in: .whitespacesAndNewlines)
                customReadingText = ""
                guard trimmed.isEmpty == false else { return }
                onApplyCustomReading?(trimmed)
            }
        } message: {
            Text(selection.surface)
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

    private var highlightedEntry: (entry: DictionaryEntry, index: Int)? {
        guard lookup.results.isEmpty == false else { return nil }
        let safeIndex = min(highlightedResultIndex, lookup.results.count - 1)
        return (lookup.results[safeIndex], safeIndex)
    }

    private func dictionaryCard(entry: DictionaryEntry, positionText: String) -> some View {
        let isSaved = isWordSaved?(entry) ?? false
        let activeReading = preferredReading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entryReading = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        let isActiveDictionaryReading = activeReading.isEmpty == false && entryReading.isEmpty == false && activeReading == entryReading
        let hasAnyDictionaryReadingMatch = activeReading.isEmpty == false && lookup.results.contains {
            let candidate = ($0.kana ?? $0.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty == false && candidate == activeReading
        }
        let isActiveCustomReading = activeReading.isEmpty == false && hasAnyDictionaryReadingMatch == false
        let shouldShowApplyReadingButton = lookup.results.count > 1

        let tokenSurface = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenReading = (selection.annotatedSpan.readingKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenPOS = (selection.annotatedSpan.partOfSpeech ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenLemma = (selection.annotatedSpan.lemmaCandidates.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let surfaceHasKanji = tokenSurface.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }

        // Treat the dictionary headword as the canonical lemma.
        let lemmaSurface: String = {
            // If the selected surface is kana-only, prefer kana lemma (avoid showing kanji).
            if surfaceHasKanji == false {
                if let kana = entry.kana, kana.isEmpty == false {
                    return kana
                }
                return tokenSurface
            }

            // Prefer MeCab's dictionary form when available (e.g. なりたくて -> なる).
            if tokenLemma.isEmpty == false {
                return tokenLemma
            }

            // Otherwise, prefer kanji headword when available.
            if entry.kanji.isEmpty == false {
                return entry.kanji
            }
            if let kana = entry.kana, kana.isEmpty == false {
                return kana
            }
            return tokenSurface
        }()

        // Use the dictionary-provided reading for the lemma when available.
        let lemmaReading: String = {
            // For kana-only surfaces, we intentionally avoid presenting a kanji lemma,
            // so a separate lemma reading is not useful.
            guard surfaceHasKanji else { return "" }
            // Only show a lemma reading when it corresponds to the displayed lemma surface.
            guard entry.kanji.isEmpty == false else { return "" }
            guard lemmaSurface == entry.kanji else { return "" }
            return (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        func trailingKanaRun(in surface: String) -> String {
            guard surface.isEmpty == false else { return "" }
            var scalars: [UnicodeScalar] = []
            for scalar in surface.unicodeScalars.reversed() {
                let isKana = (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
                if isKana {
                    scalars.append(scalar)
                } else {
                    break
                }
            }
            guard scalars.isEmpty == false else { return "" }
            return String(String.UnicodeScalarView(scalars.reversed()))
        }

        func readingIncludingOkurigana(surface: String, reading: String) -> String {
            let okurigana = trailingKanaRun(in: surface)
            guard okurigana.isEmpty == false else { return reading }
            guard reading.isEmpty == false else { return okurigana }
            return reading.hasSuffix(okurigana) ? reading : (reading + okurigana)
        }

        // Surface reading should reflect the *currently highlighted dictionary entry* so
        // paging shows alternate readings (e.g., 私: わたし / わたくし).
        let dictionaryReading = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceReadingBase = dictionaryReading.isEmpty ? tokenReading : dictionaryReading
        let surfaceReading = readingIncludingOkurigana(surface: tokenSurface, reading: surfaceReadingBase)

        let showSurfaceReading = surfaceReading.isEmpty == false && surfaceReading != tokenSurface
        let showLemmaLine = lemmaSurface.isEmpty == false && lemmaSurface != tokenSurface
        let showLemmaReading = lemmaReading.isEmpty == false && lemmaReading != lemmaSurface

        return VStack(alignment: .leading, spacing: 6) {
            // Surface (reading in parentheses)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tokenSurface.isEmpty ? "—" : tokenSurface)
                    .font(.headline)
                if showSurfaceReading {
                    Text("(\(surfaceReading))")
                        .font(.subheadline)
                }
            }

            // Lemma (reading in parentheses)
            if showLemmaLine {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(lemmaSurface)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if showLemmaReading {
                        Text("(\(lemmaReading))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // POS line above definition
            if tokenPOS.isEmpty == false {
                Text(tokenPOS)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if entry.gloss.isEmpty == false {
                Text(entry.gloss)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                if shouldShowApplyReadingButton {
                    iconActionButton(
                        systemImage: isActiveDictionaryReading ? "checkmark.circle.fill" : "checkmark.circle",
                        tint: isActiveDictionaryReading ? .accentColor : .secondary,
                        accessibilityLabel: isActiveDictionaryReading ? "Active dictionary reading" : "Apply dictionary reading"
                    ) {
                        onApplyReading(entry)
                    }
                    .disabled(canUseReading(entry) == false)
                }

                if onApplyCustomReading != nil {
                    iconActionButton(
                        systemImage: isActiveCustomReading ? "pencil.circle.fill" : "pencil.circle",
                        tint: isActiveCustomReading ? .accentColor : .secondary,
                        accessibilityLabel: isActiveCustomReading ? "Active custom reading" : "Apply custom reading"
                    ) {
                        customReadingText = ""
                        isCustomReadingPromptPresented = true
                    }
                }

                iconActionButton(
                    systemImage: isSaved ? "bookmark.fill" : "bookmark",
                    tint: isSaved ? .accentColor : .secondary,
                    accessibilityLabel: isSaved ? "Saved to words list" : "Save to words list"
                ) {
                    onSaveWord(entry)
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

    private func canUseReading(_ entry: DictionaryEntry) -> Bool {
        let candidate = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty == false
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
        preferredReading: nil,
        canMergePrevious: false,
        canMergeNext: true,
        onDismiss: {},
        onSaveWord: { _ in },
        onApplyReading: { _ in },
        onMergePrevious: {},
        onMergeNext: {},
        onSplit: { _ in },
        onReset: {},
        isSelectionCustomized: true,
        enableDragToDismiss: true,
        embedInMaterialBackground: true,
        focusSplitMenu: false,
        onSplitFocusConsumed: {}
    )
    .padding()
    .background(Color.black.opacity(0.05))
}
