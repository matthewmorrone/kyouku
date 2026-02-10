import SwiftUI
import Foundation

struct LookupResultsView: View {
    @ObservedObject var lookup: DictionaryLookupViewModel
    let selection: TokenSelectionContext
    let preferredReading: String?
    @Binding var highlightedResultIndex: Int
    @Binding var highlightedReadingIndex: Int
    let onApplyReading: (DictionaryEntry) -> Void
    let onApplyCustomReading: ((String) -> Void)?
    let onSaveWord: (DictionaryEntry) -> Void
    let isWordSaved: ((DictionaryEntry) -> Bool)?
    let onShowDefinitions: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    @State private var isCustomReadingPromptPresented = false
    @State private var customReadingText = ""

    @State private var highlightedEntryDetail: DictionaryEntryDetail? = nil
    @State private var highlightedEntryDetailTask: Task<Void, Never>? = nil

    private enum PagingMode {
        case none
        case results(current: Int, total: Int)
        case readings(current: Int, total: Int)
    }

    private struct PagingState {
        let entry: DictionaryEntry
        let mode: PagingMode

        var hasPaging: Bool {
            switch mode {
            case .none: return false
            case .results, .readings: return true
            }
        }

        var positionText: String {
            switch mode {
            case .none:
                return ""
            case .results(let current, let total):
                return "\(current)/\(total)"
            case .readings(let current, let total):
                return "\(current)/\(total)"
            }
        }
    }

    // Stable snapshot the UI should render, scoped to the current selection.
    // Without scoping, the inline panel can briefly show stale results (or "No matches")
    // while a new selection is resolving.
    private var presentedForSelection: DictionaryLookupViewModel.PresentedLookup? {
        guard let snapshot = lookup.presented, snapshot.requestID == selection.id else { return nil }
        return snapshot
    }

    private var isResolvingSelection: Bool {
        if case .resolving(let requestID) = lookup.phase {
            return requestID == selection.id
        }
        return false
    }

    private var effectiveSelection: TokenSelectionContext { presentedForSelection?.selection ?? selection }

    private var effectiveResults: [DictionaryEntry] { presentedForSelection?.results ?? [] }

    private var effectiveError: String? { presentedForSelection?.errorMessage }

    private var pagingState: PagingState? {
        guard let highlighted = highlightedEntry else { return nil }

        let resultsCount = effectiveResults.count
        let resultPaging = resultsCount > 1
        if resultPaging {
            let current = min(max(0, highlighted.index), max(0, resultsCount - 1)) + 1
            return PagingState(
                entry: highlighted.entry,
                mode: .results(current: current, total: resultsCount)
            )
        }

        let variants = readingVariants(for: highlighted.entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else {
            return PagingState(entry: highlighted.entry, mode: .none)
        }

        let safe = min(max(0, highlightedReadingIndex), max(0, variants.count - 1))
        let activeKana = variants.indices.contains(safe) ? variants[safe] : highlighted.entry.kana
        let effectiveEntry = entryWithKanaVariant(highlighted.entry, kana: activeKana)
        return PagingState(
            entry: effectiveEntry,
            mode: .readings(current: safe + 1, total: variants.count)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isResolvingSelection {
                statusCard {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking up \(effectiveSelection.surface)…")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                            .multilineTextAlignment(.leading)
                    }
                }
            } else if let error = effectiveError, error.isEmpty == false {
                statusCard {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
            } else if effectiveResults.isEmpty {
                statusCard {
                    Text("No matches for \(effectiveSelection.surface). Try editing the selection or typing a different term in the Dictionary tab.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
            } else if let state = pagingState {
                let slotWidth: CGFloat = 18
                let slotVerticalPadding: CGFloat = 48

                let prevDisabled: Bool = {
                    switch state.mode {
                    case .none:
                        return true
                    case .results:
                        return highlightedResultIndex <= 0
                    case .readings:
                        return highlightedReadingIndex <= 0
                    }
                }()

                let nextDisabled: Bool = {
                    switch state.mode {
                    case .none:
                        return true
                    case .results(_, let total):
                        return highlightedResultIndex >= max(0, total - 1)
                    case .readings(_, let total):
                        return highlightedReadingIndex >= max(0, total - 1)
                    }
                }()

                let prevLabel: String = {
                    switch state.mode {
                    case .readings: return "Previous reading"
                    default: return "Previous result"
                    }
                }()

                let nextLabel: String = {
                    switch state.mode {
                    case .readings: return "Next reading"
                    default: return "Next result"
                    }
                }()

                VStack(alignment: .leading, spacing: 12) {
                    dictionaryCard(entry: state.entry, positionText: state.positionText)
                        // Always reserve left/right space so single-result cards match the
                        // multi-result layout, but without drawing arrows.
                        .padding(.horizontal, slotWidth)
                        .simultaneousGesture(horizontalSwipeGesture)
                        // IMPORTANT: use overlays so the large hit-target padding does NOT
                        // inflate the measured panel size.
                        .overlay(alignment: .leading) {
                            if state.hasPaging {
                                pagerChevronOverlay(
                                    systemImage: "chevron.left",
                                    isDisabled: prevDisabled,
                                    verticalPadding: slotVerticalPadding,
                                    accessibilityLabel: prevLabel,
                                    action: {
                                        switch state.mode {
                                        case .results:
                                            goToPreviousResult()
                                        case .readings:
                                            goToPreviousReading()
                                        case .none:
                                            break
                                        }
                                    }
                                )
                                .frame(width: slotWidth)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if state.hasPaging {
                                pagerChevronOverlay(
                                    systemImage: "chevron.right",
                                    isDisabled: nextDisabled,
                                    verticalPadding: slotVerticalPadding,
                                    accessibilityLabel: nextLabel,
                                    action: {
                                        switch state.mode {
                                        case .results:
                                            goToNextResult()
                                        case .readings:
                                            goToNextReading()
                                        case .none:
                                            break
                                        }
                                    }
                                )
                                .frame(width: slotWidth)
                            }
                        }
                }
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            refreshHighlightedEntryDetail()
            resetReadingIndexIfNeeded()
        }
        .onChange(of: highlightedResultIndex) { _, _ in
            highlightedReadingIndex = 0
            refreshHighlightedEntryDetail()
            resetReadingIndexIfNeeded()
        }
        .onChange(of: lookup.presented?.requestID) { _, _ in
            highlightedReadingIndex = 0
            refreshHighlightedEntryDetail()
            resetReadingIndexIfNeeded()
        }

        .background(
            CustomReadingAlertPresenter(
                isPresented: $isCustomReadingPromptPresented,
                title: "Custom reading",
                surface: effectiveSelection.surface,
                text: $customReadingText,
                preferredLanguagePrefixes: ["ja"],
                onCancel: {
                    customReadingText = ""
                },
                onApply: {
                    let trimmed = customReadingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    customReadingText = ""
                    guard trimmed.isEmpty == false else { return }
                    onApplyCustomReading?(trimmed)
                }
            )
        )
    }

    private func statusCard(@ViewBuilder content: () -> some View) -> some View {
        // Match the result-card layout so status states feel like they belong to the inner panel.
        // Also reserve the left/right pager slots so single-result + status states align.
        let slotWidth: CGFloat = 18

        return content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DictionaryCardBackground(colorScheme: colorScheme))
            .padding(.horizontal, slotWidth)
    }

    private func pagerChevronOverlay(
        systemImage: String,
        isDisabled: Bool,
        verticalPadding: CGFloat,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .frame(width: 18)
                .padding(.vertical, verticalPadding)
        }
        .buttonStyle(.plain)
        .foregroundColor(isDisabled ? Color.secondary.opacity(0.4) : .accentColor)
        .contentShape(Rectangle())
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var horizontalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -30 {
                    if effectiveResults.count > 1 {
                        goToNextResult()
                    } else {
                        goToNextReading()
                    }
                } else if value.translation.width > 30 {
                    if effectiveResults.count > 1 {
                        goToPreviousResult()
                    } else {
                        goToPreviousReading()
                    }
                }
            }
    }

    private func goToPreviousResult() {
        guard highlightedResultIndex > 0 else { return }
        highlightedResultIndex -= 1
    }

    private func goToNextResult() {
        guard highlightedResultIndex < max(0, effectiveResults.count - 1) else { return }
        highlightedResultIndex += 1
        highlightedReadingIndex = 0
        resetReadingIndexIfNeeded()
    }

    private func goToPreviousReading() {
        guard let entry = highlightedEntry?.entry else { return }
        let variants = readingVariants(for: entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else { return }
        guard highlightedReadingIndex > 0 else { return }
        highlightedReadingIndex -= 1
    }

    private func goToNextReading() {
        guard let entry = highlightedEntry?.entry else { return }
        let variants = readingVariants(for: entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else { return }
        guard highlightedReadingIndex < variants.count - 1 else { return }
        highlightedReadingIndex += 1
    }

    private func resetReadingIndexIfNeeded() {
        guard effectiveResults.count <= 1 else {
            highlightedReadingIndex = 0
            return
        }
        guard let entry = highlightedEntry?.entry else {
            highlightedReadingIndex = 0
            return
        }

        let variants = readingVariants(for: entry, detail: matchingHighlightedEntryDetail)
        guard variants.count > 1 else {
            highlightedReadingIndex = 0
            return
        }

        let preferred = preferredReading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if preferred.isEmpty == false {
            if let idx = variants.firstIndex(of: preferred) {
                highlightedReadingIndex = idx
                return
            }

            // Reading overrides for mixed kanji+kana tokens are persisted as the *kanji portion*
            // of the surface reading (e.g. 抱かれ -> store "いだ" so ruby can render 抱(いだ)かれ).
            // When reopening the popup, map that persisted stem back onto the lemma-level
            // dictionary variants so the same variant is highlighted.
            let tokenSurface = effectiveSelection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let lemmaSurface = (entry.kanji.isEmpty == false ? entry.kanji : (entry.kana ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if tokenSurface.isEmpty == false, lemmaSurface.isEmpty == false {
                for (idx, variant) in variants.enumerated() {
                    let projected = projectedOverrideKana(tokenSurface: tokenSurface, lemmaSurface: lemmaSurface, lemmaReading: variant)
                    if projected == preferred {
                        highlightedReadingIndex = idx
                        return
                    }
                }
            }
        }

        let tokenReading = (effectiveSelection.annotatedSpan.readingKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if tokenReading.isEmpty == false, let idx = variants.firstIndex(of: tokenReading) {
            highlightedReadingIndex = idx
            return
        }

        let entryKana = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if entryKana.isEmpty == false, let idx = variants.firstIndex(of: entryKana) {
            highlightedReadingIndex = idx
            return
        }

        highlightedReadingIndex = 0
    }

    private var highlightedEntry: (entry: DictionaryEntry, index: Int)? {
        guard effectiveResults.isEmpty == false else { return nil }
        let safeIndex = min(highlightedResultIndex, effectiveResults.count - 1)
        return (effectiveResults[safeIndex], safeIndex)
    }

    private var matchingHighlightedEntryDetail: DictionaryEntryDetail? {
        guard let entry = highlightedEntry?.entry else { return nil }
        guard let detail = highlightedEntryDetail, detail.entryID == entry.entryID else { return nil }
        return detail
    }

    private func readingVariants(for entry: DictionaryEntry, detail: DictionaryEntryDetail?) -> [String] {
        var variants: [String] = []
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            if variants.contains(trimmed) == false {
                variants.append(trimmed)
            }
        }

        if let detail {
            for form in detail.kanaForms {
                add(form.text)
            }
        }
        if let kana = entry.kana {
            add(kana)
        }
        return variants
    }

    private func entryWithKanaVariant(_ entry: DictionaryEntry, kana: String?) -> DictionaryEntry {
        guard let kana else { return entry }
        guard kana.isEmpty == false else { return entry }
        guard entry.kana != kana else { return entry }
        return DictionaryEntry(
            entryID: entry.entryID,
            kanji: entry.kanji,
            kana: kana,
            gloss: entry.gloss,
            isCommon: entry.isCommon
        )
    }

    private func refreshHighlightedEntryDetail() {
        highlightedEntryDetailTask?.cancel()
        highlightedEntryDetailTask = nil

        guard let entry = highlightedEntry?.entry else {
            highlightedEntryDetail = nil
            return
        }

        highlightedEntryDetailTask = Task {
            let detail = (try? await DictionarySQLiteStore.shared.fetchEntryDetails(for: [entry.entryID]).first)
            if Task.isCancelled { return }
            highlightedEntryDetail = detail
        }
    }

    private var shouldShowApplyReadingButton: Bool {
        true
    }

    private var isActiveDictionaryReading: Bool {
        guard let entry = highlightedEntry?.entry else { return false }
        let tokenReading = (effectiveSelection.annotatedSpan.readingKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        return tokenReading.isEmpty == false && candidate.isEmpty == false && tokenReading == candidate
    }

    private func dictionaryCard(entry: DictionaryEntry, positionText: String) -> some View {
        let tokenSurface = effectiveSelection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let lemmaSurface = (entry.kanji.isEmpty == false ? entry.kanji : (entry.kana ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let surfaceReading = (effectiveSelection.annotatedSpan.readingKana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let showSurfaceReading: Bool = {
            guard surfaceReading.isEmpty == false else { return false }
            guard tokenSurface.isEmpty == false else { return false }
            guard isKanaOnlySurface(tokenSurface) == false else { return false }
            // For mixed kanji+kana tokens, show the surface reading so the user can
            // quickly confirm overrides.
            return tokenSurface != lemmaSurface
        }()

        let variants = readingVariants(for: entry, detail: matchingHighlightedEntryDetail)
        let readingChipText = variants.indices.contains(highlightedReadingIndex) ? variants[highlightedReadingIndex] : (entry.kana ?? "")
        let readingChipEnabled = canUseReading(entry)

        let isSaved = isWordSaved?(entry) ?? false

        let glossPreview: String = {
            if let detail = matchingHighlightedEntryDetail {
                let glosses = detail.senses
                    .flatMap { $0.glosses }
                    .sorted(by: { $0.orderIndex < $1.orderIndex })
                    .map { $0.text }
                    .joined(separator: "; ")
                return glosses
            }
            return entry.gloss
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.kanji.isEmpty == false ? entry.kanji : (entry.kana ?? ""))
                        .font(.headline)
                    if showSurfaceReading {
                        Text(surfaceReading)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if variants.isEmpty == false {
                    Button {
                        if variants.count > 1 {
                            highlightedReadingIndex = (highlightedReadingIndex + 1) % variants.count
                        }
                    } label: {
                        Text(readingChipText)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(readingChipEnabled ? Color.accentColor : .secondary)
                    .disabled(readingChipEnabled == false)
                    .accessibilityLabel("Reading variants")
                }
            }

            if glossPreview.isEmpty == false {
                ExpandableGlossPreview(entryID: entry.entryID, gloss: glossPreview)
            }

            HStack(spacing: 8) {
                if onApplyCustomReading != nil {
                    iconActionButton(
                        systemImage: "pencil",
                        tint: .secondary,
                        accessibilityLabel: "Custom reading"
                    ) {
                        customReadingText = preferredReading ?? (effectiveSelection.annotatedSpan.readingKana ?? "")
                        isCustomReadingPromptPresented = true
                    }
                }

                inlineIconButton(
                    systemImage: "speaker.wave.2",
                    tint: .secondary,
                    accessibilityLabel: "Speak"
                ) {
                    let speechText = showSurfaceReading ? surfaceReading : tokenSurface
                    SpeechManager.shared.speak(text: speechText, language: "ja-JP")
                }

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

                if let onShowDefinitions {
                    iconActionButton(
                        systemImage: "book",
                        tint: .secondary,
                        accessibilityLabel: "Show details"
                    ) {
                        onShowDefinitions()
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
        .background(DictionaryCardBackground(colorScheme: colorScheme))
        .overlay(alignment: .topTrailing) {
            if positionText.isEmpty == false {
                Text(positionText)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
        }
    }

    private struct DictionaryCardBackground: View {
        let colorScheme: ColorScheme

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            let material: Material = (colorScheme == .dark) ? .regularMaterial : .thinMaterial
            let tint: Color = (colorScheme == .dark) ? Color.black.opacity(0.32) : Color.black.opacity(0.12)
            let border: Color = (colorScheme == .dark) ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
            let shadowOpacity: Double = (colorScheme == .dark) ? 0.30 : 0.10

            ZStack {
                shape.fill(material)
                shape.fill(tint).blendMode(.multiply)
                shape.stroke(border, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 10, x: 0, y: 4)
        }
    }

    private struct ExpandableGlossPreview: View {
        let entryID: Int64
        let gloss: String

        @State private var isExpanded: Bool = false

        private let collapsedLimit: Int = 3

        private var pieces: [String] {
            gloss
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        }

        private var hiddenCount: Int {
            max(0, pieces.count - collapsedLimit)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                let shown = isExpanded ? pieces : Array(pieces.prefix(collapsedLimit))
                if shown.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { idx, text in
                            Text("\(idx + 1). \(text)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                }

                if hiddenCount > 0 {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "Show less" : "Show \(hiddenCount) more")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Show fewer definitions" : "Show more definitions")
                }
            }
            .id(entryID)
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

    private func inlineIconButton(systemImage: String, tint: Color, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .frame(width: 18, height: 18)
                .padding(.leading, 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .accessibilityLabel(accessibilityLabel)
    }

    private func canUseReading(_ entry: DictionaryEntry) -> Bool {
        let candidate = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty == false
    }

    private func isKanaOnlySurface(_ surface: String) -> Bool {
        guard surface.isEmpty == false else { return false }
        return surface.unicodeScalars.allSatisfy { scalar in
            (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
        }
    }

    /// Project a lemma-level reading (dictionary kana variant) into the persisted override form.
    /// This mirrors the storage logic in PasteView.applyDictionaryReading(_:).
    private func projectedOverrideKana(tokenSurface: String, lemmaSurface: String, lemmaReading: String) -> String {
        let baseReading = lemmaReading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard baseReading.isEmpty == false else { return "" }

        func trailingKanaRun(in surface: String) -> String {
            guard surface.isEmpty == false else { return "" }
            let allScalars = Array(surface.unicodeScalars)
            guard allScalars.isEmpty == false else { return "" }
            var trailing: [UnicodeScalar] = []
            for scalar in allScalars.reversed() {
                let isKana = (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
                if isKana {
                    trailing.append(scalar)
                } else {
                    break
                }
            }
            guard trailing.isEmpty == false, trailing.count < allScalars.count else { return "" }
            return String(String.UnicodeScalarView(trailing.reversed()))
        }

        let tokenSuffix = trailingKanaRun(in: tokenSurface)
        let lemmaSuffix = trailingKanaRun(in: lemmaSurface)

        let surfaceReading: String = {
            guard tokenSuffix.isEmpty == false else { return baseReading }
            guard lemmaSuffix.isEmpty == false else { return baseReading }
            guard baseReading.hasSuffix(lemmaSuffix) else { return baseReading }
            let stem = String(baseReading.dropLast(lemmaSuffix.count))
            return stem + tokenSuffix
        }()

        if tokenSuffix.isEmpty == false,
           surfaceReading.hasSuffix(tokenSuffix),
           isKanaOnlySurface(tokenSurface) == false,
           tokenSurface.utf16.count > tokenSuffix.utf16.count {
            return String(surfaceReading.dropLast(tokenSuffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return surfaceReading.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
