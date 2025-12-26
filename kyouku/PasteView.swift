import SwiftUI
import UIKit
import Foundation
import OSLog

struct PasteView: View {
    @EnvironmentObject var notes: NotesStore
    private struct TokenActionPanelFramePreferenceKey: PreferenceKey {
        static var defaultValue: CGRect? = nil

        static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
            if let next = nextValue() {
                value = next
            }
        }
    }
    private struct SheetPanelHeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var words: WordsStore
    @EnvironmentObject var readingOverrides: ReadingOverridesStore
    @Environment(\.undoManager) private var undoManager

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var noteTitleInput: String = ""
    @State private var hasManuallyEditedTitle: Bool = false
    @State private var hasInitialized: Bool = false
    @State private var isEditing: Bool = false
    @State private var furiganaAttributedText: NSAttributedString? = nil
    @State private var furiganaSpans: [AnnotatedSpan]? = nil
    @State private var furiganaRefreshToken: Int = 0
    @State private var furiganaTaskHandle: Task<Void, Never>? = nil
    @State private var suppressNextEditingRefresh: Bool = false
    @StateObject private var inlineLookup = DictionaryLookupViewModel()
    @State private var tokenSelection: TokenSelectionContext? = nil
    @State private var persistentSelectionRange: NSRange? = nil
    @State private var overrideSignature: Int = 0
    @State private var customizedRanges: [NSRange] = []
    @State private var tokenPanelFrame: CGRect? = nil
    @State private var sheetSelection: TokenSelectionContext? = nil
    @State private var sheetPanelHeight: CGFloat = 0
    @State private var pendingSelectionRange: NSRange? = nil

    @AppStorage("readingTextSize") private var readingTextSize: Double = 17
    @AppStorage("readingFuriganaSize") private var readingFuriganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var readingLineSpacing: Double = 4
    @AppStorage("readingShowFurigana") private var showFurigana: Bool = true
    @AppStorage("readingAlternateTokenColors") private var alternateTokenColors: Bool = false
    @AppStorage("readingHighlightUnknownTokens") private var highlightUnknownTokens: Bool = false
    @AppStorage("readingAlternateTokenColorA") private var alternateTokenColorAHex: String = "#0A84FF"
    @AppStorage("readingAlternateTokenColorB") private var alternateTokenColorBHex: String = "#FF2D55"
    @AppStorage("pasteViewScratchNoteID") private var scratchNoteIDRaw: String = ""

    private var scratchNoteID: UUID {
        if let cached = UUID(uuidString: scratchNoteIDRaw) {
            return cached
        }
        let newID = UUID()
        scratchNoteIDRaw = newID.uuidString
        return newID
    }

    private static let furiganaLogger = DiagnosticsLogging.logger(.furigana)
    private static let selectionLogger = DiagnosticsLogging.logger(.pasteSelection)
    private static let coordinateSpaceName = "PasteViewRootSpace"
    private static let inlineDictionaryPanelEnabledFlag = false
    private static let sheetMaxHeightFraction: CGFloat = 0.8
    private static let sheetExtraPadding: CGFloat = 36
    private var inlineDictionaryPanelEnabled: Bool { Self.inlineDictionaryPanelEnabledFlag }
    private var sheetDictionaryPanelEnabled: Bool { inlineDictionaryPanelEnabled == false }
    private static let highlightWhitespace: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(CharacterSet(charactersIn: "\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{200B}"))
        return set
    }()
    private var alternateTokenPalette: [UIColor] {
        [
            UIColor(hexString: alternateTokenColorAHex) ?? .systemBlue,
            UIColor(hexString: alternateTokenColorBHex) ?? .systemPink
        ]
    }
    private var unknownTokenColor: UIColor { UIColor.systemOrange }
    private var tokenHighlightsEnabled: Bool { alternateTokenColors || highlightUnknownTokens }

    var body: some View {
        NavigationStack {
            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if inlineDictionaryPanelEnabled {
            inlineDictionaryContainer
        } else {
            applyDictionarySheet(to: coreContent)
        }
    }

    @ViewBuilder
    private var inlineDictionaryContainer: some View {
        if #available(iOS 17.0, *) {
            coreContent
                .coordinateSpace(name: Self.coordinateSpaceName)
                .onPreferenceChange(TokenActionPanelFramePreferenceKey.self) { frame in
                    tokenPanelFrame = frame
                }
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        handleTapOutsidePanel(at: value.location)
                    },
                    including: .all
                )
        } else {
            coreContent
        }
    }

    private var coreContent: some View {
        ZStack(alignment: .bottom) {
            editorColumn
            inlineDictionaryOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(currentNote?.title ?? "Paste")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if tokenSelection == nil {
                Color.clear.frame(height: 24)
            }
        }
        .onAppear { onAppearHandler() }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            furiganaTaskHandle?.cancel()
        }
        .onChange(of: inputText) { _, newValue in
            clearSelection()
            DispatchQueue.main.async {
                syncNoteForInputChange(newValue)
            }
            PasteBufferStore.save(newValue)
            if newValue.isEmpty {
                furiganaAttributedText = nil
                furiganaSpans = nil
                furiganaTaskHandle?.cancel()
            }
            triggerFuriganaRefreshIfNeeded(reason: "input changed", recomputeSpans: true)
        }
        .onChange(of: isEditing) { _, editing in
            if editing {
                clearSelection()
                furiganaAttributedText = nil
                furiganaSpans = nil
                furiganaTaskHandle?.cancel()
            } else {
                if suppressNextEditingRefresh {
                    suppressNextEditingRefresh = false
                    Self.logFurigana("Skipping refresh: editing toggle was programmatic.")
                    return
                }
                triggerFuriganaRefreshIfNeeded(reason: "editing toggled off", recomputeSpans: true)
            }
        }
        .onChange(of: showFurigana) { _, enabled in
            if enabled {
                triggerFuriganaRefreshIfNeeded(reason: "show furigana toggled on", recomputeSpans: false)
            } else {
                furiganaTaskHandle?.cancel()
            }
        }
        .onChange(of: alternateTokenColors) { _, enabled in
            if enabled {
                triggerFuriganaRefreshIfNeeded(reason: "alternate token colors toggled on", recomputeSpans: false)
            }
        }
        .onChange(of: highlightUnknownTokens) { _, enabled in
            if enabled {
                triggerFuriganaRefreshIfNeeded(reason: "unknown highlight toggled on", recomputeSpans: false)
            }
        }
        .onChange(of: readingFuriganaSize) { _, _ in
            triggerFuriganaRefreshIfNeeded(reason: "furigana font size changed", recomputeSpans: false)
        }
        .onChange(of: tokenSelection?.surface ?? "") { _, newValue in
            handleSelectionLookup(for: newValue)
        }
        .onChange(of: currentNote?.id) { _, _ in
            clearSelection()
            overrideSignature = computeOverrideSignature()
            updateCustomizedRanges()
        }
        .onReceive(readingOverrides.$overrides) { _ in
            handleOverridesExternalChange()
        }
        .onChange(of: tokenSelection == nil) { _, isNil in
            if isNil {
                tokenPanelFrame = nil
            }
        }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            EditorContainer(
                text: $inputText,
                furiganaText: furiganaAttributedText,
                furiganaSpans: furiganaSpans,
                textSize: readingTextSize,
                isEditing: isEditing,
                showFurigana: showFurigana,
                lineSpacing: readingLineSpacing,
                alternateTokenColors: alternateTokenColors,
                highlightUnknownTokens: highlightUnknownTokens,
                tokenPalette: alternateTokenPalette,
                unknownTokenColor: unknownTokenColor,
                selectedRangeHighlight: persistentSelectionRange,
                customizedRanges: customizedRanges,
                onTokenSelection: handleTokenSelection,
                onSelectionCleared: { clearSelection() },
                title: noteTitleBinding
            )
            .padding(.vertical, 16)
            .padding(.horizontal, 16)

            if tokenSelection == nil {
                editorToolbar
            }
        }
    }

    private var editorToolbar: some View {
        HStack(alignment: .center, spacing: 0) {
            ControlCell {
                Button { hideKeyboard() } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.title2)
                }
                .accessibilityLabel("Hide Keyboard")
            }

            ControlCell {
                Button(action: pasteFromClipboard) {
                    Image(systemName: "doc.on.clipboard").font(.title2)
                }
                .accessibilityLabel("Paste")
            }

            ControlCell {
                Button(action: saveNote) {
                    Image(systemName: "square.and.arrow.down").font(.title2)
                }
                .accessibilityLabel("Save")
            }

            ControlCell {
                Button {
                    guard isEditing == false else { return }
                    showFurigana.toggle()
                    if showFurigana {
                        triggerFuriganaRefreshIfNeeded(reason: "manual toggle button")
                    }
                } label: {
                    ZStack {
                        Color.clear.frame(width: 28, height: 28)
                        Image(showFurigana ? "furigana.on" : "furigana.off")
                            .renderingMode(.template)
                            .foregroundColor(.accentColor)
                            .font(.system(size: 22))
                    }
                }
                .tint(.accentColor)
                .buttonStyle(.plain)
                .accessibilityLabel(showFurigana ? "Disable Furigana" : "Enable Furigana")
                .opacity(isEditing ? 0.45 : 1.0)
                .contextMenu {
                    Toggle(isOn: $alternateTokenColors) {
                        Label("Alternate Token Colors", systemImage: "textformat.alt")
                    }
                    Toggle(isOn: $highlightUnknownTokens) {
                        Label("Highlight Unknown Words", systemImage: "questionmark.square.dashed")
                    }
                }
            }

            ControlCell {
                Toggle(isOn: $isEditing) {
                    if UIImage(systemName: "character.cursor.ibeam.ja") != nil {
                        Image(systemName: "character.cursor.ibeam.ja")
                    } else {
                        Image(systemName: "character.cursor.ibeam")
                    }
                }
                .labelsHidden()
                .toggleStyle(.button)
                .tint(.accentColor)
                .font(.title2)
                .accessibilityLabel("Edit")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var inlineDictionaryOverlay: some View {
        if inlineDictionaryPanelEnabled {
            if tokenSelection != nil {
                legacyDismissOverlay
            }
            if let selection = tokenSelection, selection.range.length > 0 {
                inlineTokenActionPanel(for: selection)
            }
        }
    }

    private func inlineTokenActionPanel(for selection: TokenSelectionContext) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            TokenActionPanel(
                selection: selection,
                lookup: inlineLookup,
                canMergePrevious: canMergeSelection(.previous),
                canMergeNext: canMergeSelection(.next),
                onDismiss: { clearSelection(resetPersistent: false) },
                onDefine: { entry in
                    defineWord(using: entry)
                },
                onUseReading: { entry in
                    applyDictionaryReading(entry)
                },
                onMergePrevious: { mergeSelection(.previous) },
                onMergeNext: { mergeSelection(.next) },
                onSplit: { offset in splitSelection(at: offset) },
                onReset: resetSelectionOverrides,
                isSelectionCustomized: selectionIsCustomized(selection),
                enableDragToDismiss: true,
                embedInMaterialBackground: true
            )
            .padding(.horizontal, 0)
            .padding(.bottom, 0)
            .ignoresSafeArea(edges: .bottom)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TokenActionPanelFramePreferenceKey.self,
                        value: proxy.frame(in: .named(Self.coordinateSpaceName))
                    )
                }
            )
        }
        .zIndex(1)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func pasteFromClipboard() {
        if let str = UIPasteboard.general.string {
            inputText = str
        }
    }

    private func saveNote() {
        guard inputText.isEmpty == false else { return }
        let resolvedTitle = normalizedTitle(noteTitleInput) ?? inferredTitle(from: inputText)
        if var existing = currentNote {
            existing.text = inputText
            existing.title = resolvedTitle
            notes.updateNote(existing)
            currentNote = existing
            noteTitleInput = resolvedTitle ?? ""
        } else {
            notes.addNote(title: resolvedTitle, text: inputText)
            if let newest = notes.notes.first {
                currentNote = newest
                noteTitleInput = newest.title ?? ""
            }
        }
    }

    private func newNote() {
        hideKeyboard()
        setEditing(true)

        inputText = ""
        notes.addNote(title: nil, text: "")
        notes.save()

        if let newest = notes.notes.first {
            currentNote = newest
            noteTitleInput = newest.title ?? ""
            hasManuallyEditedTitle = (newest.title?.isEmpty == false)
        }
        else if let last = notes.notes.last {
            currentNote = last
            noteTitleInput = last.title ?? ""
            hasManuallyEditedTitle = (last.title?.isEmpty == false)
        }
        else {
            currentNote = nil
            noteTitleInput = ""
            hasManuallyEditedTitle = false
        }

        PasteBufferStore.save("")
        furiganaAttributedText = nil
        furiganaSpans = nil
    }

    private func onAppearHandler() {
        if let note = router.noteToOpen {
            currentNote = note
            inputText = note.text
            noteTitleInput = note.title ?? ""
            hasManuallyEditedTitle = (note.title?.isEmpty == false)
            if router.pasteShouldBeginEditing {
                setEditing(true)
            }
            else {
                setEditing(false, suppressRefresh: true)
            }
            router.pasteShouldBeginEditing = false
            router.noteToOpen = nil
        }
        if !hasInitialized {
            if inputText.isEmpty {
                setEditing(true)
            }
            hasInitialized = true
        }
        if currentNote == nil && inputText.isEmpty {
            let persisted = PasteBufferStore.load()
            if !persisted.isEmpty {
                inputText = persisted
                setEditing(false, suppressRefresh: true)
            }
            noteTitleInput = ""
            hasManuallyEditedTitle = false
        }
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
    }

    private func syncNoteForInputChange(_ newValue: String) {
        guard let existing = currentNote else { return }
        var updated = existing
        updated.text = newValue
        let nextTitle: String?
        if hasManuallyEditedTitle == false {
            let fallback = inferredTitle(from: newValue)
            nextTitle = fallback
            noteTitleInput = fallback ?? ""
        } else {
            nextTitle = normalizedTitle(noteTitleInput)
        }
        updated.title = nextTitle
        notes.updateNote(updated)
        currentNote = updated
    }

    private var noteTitleBinding: Binding<String>? {
        guard currentNote != nil else { return nil }
        return Binding(
            get: { noteTitleInput },
            set: { newValue in
                noteTitleInput = newValue
                hasManuallyEditedTitle = true
                syncNoteTitleChange(newValue)
            }
        )
    }

    private func syncNoteTitleChange(_ newValue: String) {
        guard var existing = currentNote else { return }
        let normalized = normalizedTitle(newValue)
        if normalized == existing.title {
            return
        }
        existing.title = normalized
        notes.updateNote(existing)
        currentNote = existing
    }

    private func normalizedTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func inferredTitle(from text: String) -> String? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var activeNoteID: UUID {
        currentNote?.id ?? scratchNoteID
    }

    private func clearSelection(resetPersistent: Bool = true) {
        Self.selectionLogger.debug("Clearing selection resetPersistent=\(resetPersistent)")
        if resetPersistent {
            persistentSelectionRange = nil
        }
        tokenSelection = nil
        sheetSelection = nil
        sheetPanelHeight = 0
        pendingSelectionRange = nil
        Task { @MainActor in
            inlineLookup.results = []
            inlineLookup.errorMessage = nil
            inlineLookup.isLoading = false
        }
    }

    @MainActor
    private func beginPendingSelectionRestoration(for range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        pendingSelectionRange = range
        persistentSelectionRange = range
    }

    private func handleSelectionLookup(for term: String) {
        guard term.isEmpty == false else {
            Task { @MainActor in
                inlineLookup.results = []
                inlineLookup.errorMessage = nil
                inlineLookup.isLoading = false
            }
            return
        }
        let lemmaFallbacks = tokenSelection?.annotatedSpan.lemmaCandidates ?? []
        Task { [lemmaFallbacks] in
            await inlineLookup.load(term: term, fallbackTerms: lemmaFallbacks)
        }
    }

    private func applyDictionarySheet<Content: View>(to view: Content) -> AnyView {
        if sheetDictionaryPanelEnabled {
            return AnyView(
                view.sheet(item: $sheetSelection, onDismiss: { clearSelection(resetPersistent: false) }) { selection in
                    let sheetPanel = TokenActionPanel(
                        selection: selection,
                        lookup: inlineLookup,
                        canMergePrevious: canMergeSelection(.previous),
                        canMergeNext: canMergeSelection(.next),
                        onDismiss: { clearSelection(resetPersistent: false) },
                        onDefine: { entry in
                            defineWord(using: entry)
                        },
                        onUseReading: { entry in
                            applyDictionaryReading(entry)
                        },
                        onMergePrevious: { mergeSelection(.previous) },
                        onMergeNext: { mergeSelection(.next) },
                        onSplit: { offset in splitSelection(at: offset) },
                        onReset: resetSelectionOverrides,
                        isSelectionCustomized: selectionIsCustomized(selection),
                        enableDragToDismiss: false,
                        embedInMaterialBackground: false
                    )

                    sheetPanel
                        .overlay(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: SheetPanelHeightPreferenceKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                        .onPreferenceChange(SheetPanelHeightPreferenceKey.self) { newValue in
                            sheetPanelHeight = newValue
                        }
                        .presentationDragIndicator(.visible)
                        .presentationDetents([
                            .height(max(sheetPanelHeight + 50, 300))
                        ])
                        .presentationBackgroundInteraction(.enabled)
                }
            )
        } else {
            return AnyView(view)
        }
    }

    private func preferredSheetDetentHeight() -> CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        let fallback = screenHeight * 0.45
        guard sheetPanelHeight > 0 else { return fallback }
        let padded = sheetPanelHeight + Self.sheetExtraPadding
        let maxHeight = screenHeight * Self.sheetMaxHeightFraction
        let minHeight: CGFloat = 280
        return min(max(padded, minHeight), maxHeight)
    }

    @available(iOS 17.0, *)
    private func handleTapOutsidePanel(at location: CGPoint) {
        guard tokenSelection != nil else { return }
        if let frame = tokenPanelFrame, frame.contains(location) {
            return
        }
        clearSelection(resetPersistent: false)
    }

    @ViewBuilder
    private var legacyDismissOverlay: some View {
        if #available(iOS 17.0, *) {
            EmptyView()
        }
        else {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { clearSelection(resetPersistent: false) }
                .transition(.opacity)
                .zIndex(0.5)
        }
    }

    private func handleTokenSelection(_ payload: RubyText.SelectionPayload) {
        guard isEditing == false else { return }
        let range = payload.range
        guard range.location != NSNotFound, range.length > 0 else { return }
        guard NSMaxRange(range) <= (inputText as NSString).length else { return }
        guard let trimmed = trimmedSelection(from: payload) else {
            Self.selectionLogger.debug("Token selection ignored spanIndex=\(payload.index) reason=whitespace-only")
            return
        }
        Self.selectionLogger.debug("Token selected spanIndex=\(payload.index) rawRange=\(range.location)-\(NSMaxRange(range)) highlight=\(trimmed.range.location)-\(NSMaxRange(trimmed.range)) surface=\(trimmed.surface, privacy: .public)")
        persistentSelectionRange = trimmed.range
        let context = TokenSelectionContext(
            spanIndex: payload.index,
            range: trimmed.range,
            surface: trimmed.surface,
            annotatedSpan: payload.span
        )
        tokenSelection = context
        if sheetDictionaryPanelEnabled {
            sheetSelection = context
        }
    }

    private func trimmedSelection(from payload: RubyText.SelectionPayload) -> (range: NSRange, surface: String)? {
        let local = payload.span.span.surface as NSString
        let localLength = local.length
        guard localLength > 0 else { return nil }
        var start = 0
        var end = localLength
        let whitespace = Self.highlightWhitespace
        while start < end {
            let scalarValue = local.character(at: start)
            if let scalar = UnicodeScalar(scalarValue), whitespace.contains(scalar) {
                start += 1
                continue
            }
            break
        }
        while end > start {
            let scalarValue = local.character(at: end - 1)
            if let scalar = UnicodeScalar(scalarValue), whitespace.contains(scalar) {
                end -= 1
                continue
            }
            break
        }
        guard end > start else { return nil }
        let trimmedLocalRange = NSRange(location: start, length: end - start)
        let highlightRange = NSRange(location: payload.range.location + trimmedLocalRange.location, length: trimmedLocalRange.length)
        let trimmedSurface = local.substring(with: trimmedLocalRange)
        return (highlightRange, trimmedSurface)
    }

    private func handleOverridesExternalChange() {
        let signature = computeOverrideSignature()
        guard signature != overrideSignature else { return }
        Self.selectionLogger.debug("Override change detected for note=\(activeNoteID)")
        overrideSignature = signature
        updateCustomizedRanges()
        guard inputText.isEmpty == false else { return }
        guard showFurigana || tokenHighlightsEnabled else { return }
        guard isEditing == false else { return }
        triggerFuriganaRefreshIfNeeded(reason: "reading overrides changed", recomputeSpans: true)
    }

    private func computeOverrideSignature() -> Int {
        let overrides = readingOverrides.overrides(for: activeNoteID).sorted { lhs, rhs in
            if lhs.rangeStart == rhs.rangeStart {
                return lhs.rangeLength < rhs.rangeLength
            }
            return lhs.rangeStart < rhs.rangeStart
        }
        var hasher = Hasher()
        hasher.combine(overrides.count)
        for override in overrides {
            hasher.combine(override.rangeStart)
            hasher.combine(override.rangeLength)
            hasher.combine(override.userKana ?? "")
        }
        return hasher.finalize()
    }

    private func updateCustomizedRanges() {
        let overrides = readingOverrides.overrides(for: activeNoteID)
        customizedRanges = overrides.map { $0.nsRange }
    }

    private func defineWord(using entry: DictionaryEntry) {
        guard let selection = tokenSelection else { return }
        let surface = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let gloss = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
        guard surface.isEmpty == false, gloss.isEmpty == false else { return }
        words.add(surface: surface, kana: entry.kana, meaning: gloss, note: nil, sourceNoteID: currentNote?.id)
    }

    private func applyDictionaryReading(_ entry: DictionaryEntry) {
        guard let selection = tokenSelection else { return }
        let rawKana = entry.kana ?? entry.kanji
        let trimmedKana = rawKana.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedKana.isEmpty == false else { return }
        let override = ReadingOverride(
            noteID: activeNoteID,
            rangeStart: selection.range.location,
            rangeLength: selection.range.length,
            userKana: trimmedKana
        )
        applyOverridesChange(range: selection.range, newOverrides: [override], actionName: "Apply Reading")
    }

    private func mergeSelection(_ direction: MergeDirection) {
        guard let selection = tokenSelection else { return }
        guard let spans = furiganaSpans else { return }
        guard let neighborIndex = neighborIndex(for: selection.spanIndex, direction: direction), spans.indices.contains(neighborIndex) else { return }
        let currentRange = spans[selection.spanIndex].span.range
        let neighborRange = spans[neighborIndex].span.range
        let union = NSUnionRange(currentRange, neighborRange)
        let override = ReadingOverride(
            noteID: activeNoteID,
            rangeStart: union.location,
            rangeLength: union.length,
            userKana: nil
        )
        applyOverridesChange(range: union, newOverrides: [override], actionName: "Merge Tokens")
        clearSelection(resetPersistent: false)
        beginPendingSelectionRestoration(for: union)
    }

    private func splitSelection(at offset: Int) {
        guard let selection = tokenSelection else { return }
        guard selection.range.length > 1 else { return }
        guard offset > 0, offset < selection.range.length else { return }
        let leftRange = NSRange(location: selection.range.location, length: offset)
        let rightRange = NSRange(location: selection.range.location + offset, length: selection.range.length - offset)
        let overridesToInsert = [leftRange, rightRange].map { subRange in
            ReadingOverride(
                noteID: activeNoteID,
                rangeStart: subRange.location,
                rangeLength: subRange.length,
                userKana: nil
            )
        }
        applyOverridesChange(range: selection.range, newOverrides: overridesToInsert, actionName: "Split Token")
        clearSelection(resetPersistent: false)
    }

    private func resetSelectionOverrides() {
        guard let selection = tokenSelection else { return }
        applyOverridesChange(range: selection.range, newOverrides: [], actionName: "Reset Token")
        clearSelection(resetPersistent: false)
    }

    private func resetAllCustomSpans() {
        let noteID = activeNoteID
        readingOverrides.removeAll(for: noteID)
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        clearSelection()
        triggerFuriganaRefreshIfNeeded(reason: "reset all overrides", recomputeSpans: true)
    }

    private func applyOverridesChange(range: NSRange, newOverrides: [ReadingOverride], actionName: String) {
        let noteID = activeNoteID
        let previous = readingOverrides.overrides(for: noteID, overlapping: range)
        Self.selectionLogger.debug("Applying overrides action=\(actionName, privacy: .public) note=\(noteID) range=\(range.location)-\(NSMaxRange(range)) replacing=\(previous.count) inserting=\(newOverrides.count)")
        readingOverrides.apply(noteID: noteID, removing: range, adding: newOverrides)
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        triggerFuriganaRefreshIfNeeded(reason: "manual token override", recomputeSpans: true)
        registerUndo(previousOverrides: previous, range: range, actionName: actionName)
    }

    private func registerUndo(previousOverrides: [ReadingOverride], range: NSRange, actionName: String) {
        guard let undoManager else { return }
        let token = OverrideUndoToken { [self] in
            applyOverridesChange(range: range, newOverrides: previousOverrides, actionName: actionName)
        }
        undoManager.registerUndo(withTarget: token) { target in
            target.perform()
        }
        undoManager.setActionName(actionName)
    }

    private func canMergeSelection(_ direction: MergeDirection) -> Bool {
        guard let selection = tokenSelection else { return false }
        guard let spans = furiganaSpans else { return false }
        guard let neighbor = neighborIndex(for: selection.spanIndex, direction: direction) else { return false }
        return spans.indices.contains(neighbor)
    }

    private func selectionIsCustomized(_ selection: TokenSelectionContext) -> Bool {
        customizedRanges.contains { NSIntersectionRange($0, selection.range).length > 0 }
    }

    private func neighborIndex(for index: Int, direction: MergeDirection) -> Int? {
        switch direction {
        case .previous:
            return index - 1
        case .next:
            return index + 1
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func setEditing(_ editing: Bool, suppressRefresh: Bool = false) {
        if suppressRefresh && editing == false {
            suppressNextEditingRefresh = true
        }
        isEditing = editing
    }

    private func triggerFuriganaRefreshIfNeeded(reason: String = "state change", recomputeSpans: Bool = true) {
        guard showFurigana || tokenHighlightsEnabled else {
            Self.logFurigana("Skipping refresh (\(reason)): no consumers need annotated spans.")
            return
        }
        guard isEditing == false else {
            Self.logFurigana("Skipping refresh (\(reason)): editor is in edit mode.")
            return
        }
        guard inputText.isEmpty == false else {
            Self.logFurigana("Skipping refresh (\(reason)): paste text is empty.")
            return
        }
        furiganaRefreshToken &+= 1
        Self.logFurigana("Queued refresh token \(furiganaRefreshToken) for text length \(inputText.count). Reason: \(reason)")
        startFuriganaTask(token: furiganaRefreshToken, recomputeSpans: recomputeSpans)
    }

    private func startFuriganaTask(token: Int, recomputeSpans: Bool) {
        guard let taskBody = makeFuriganaTask(token: token, recomputeSpans: recomputeSpans) else { return }
        furiganaTaskHandle?.cancel()
        furiganaTaskHandle = Task {
            await taskBody()
        }
    }

    private func makeFuriganaTask(token: Int, recomputeSpans: Bool) -> (() async -> Void)? {
        guard showFurigana || tokenHighlightsEnabled else {
            Self.logFurigana("No furigana task created because no consumer requires spans.")
            return nil
        }
        guard inputText.isEmpty == false else {
            Self.logFurigana("No furigana task created because text is empty.")
            return nil
        }
        // Capture current values by value to avoid capturing self
        let currentText = inputText
        let currentShowFurigana = showFurigana
        let currentAlternateTokenColors = alternateTokenColors
        let currentHighlightUnknownTokens = highlightUnknownTokens
        let currentIsEditing = isEditing
        let currentTextSize = readingTextSize
        let currentFuriganaSize = readingFuriganaSize
        let currentSpans = furiganaSpans
        let currentOverrides = readingOverrides.overrides(for: activeNoteID)
        Self.logFurigana("Creating furigana task token \(token) for text length \(currentText.count). ShowF: \(currentShowFurigana), isEditing: \(currentIsEditing)")
        return {
            await PasteView.recomputeFurigana(
                text: currentText,
                showFurigana: currentShowFurigana,
                needsTokenHighlights: (currentAlternateTokenColors || currentHighlightUnknownTokens),
                isEditing: currentIsEditing,
                textSize: currentTextSize,
                furiganaSize: currentFuriganaSize,
                recomputeSpans: recomputeSpans,
                existingSpans: currentSpans,
                overrides: currentOverrides
            ) { newSpans, newAttributed in
                // Only update if state still matches to avoid stale updates
                if inputText == currentText && showFurigana == currentShowFurigana && isEditing == currentIsEditing {
                    furiganaSpans = newSpans
                    furiganaAttributedText = newAttributed
                    restoreSelectionIfNeeded()
                }
            }
        }
    }

    @MainActor
    private func restoreSelectionIfNeeded() {
        guard let targetRange = pendingSelectionRange else { return }
        guard let spans = furiganaSpans else { return }
        guard let match = spans.enumerated().first(where: { $0.element.span.range == targetRange }) else { return }
        let textStorage = inputText as NSString
        guard NSMaxRange(targetRange) <= textStorage.length else {
            pendingSelectionRange = nil
            return
        }
        let surface = textStorage.substring(with: targetRange)
        let context = TokenSelectionContext(
            spanIndex: match.offset,
            range: targetRange,
            surface: surface,
            annotatedSpan: match.element
        )
        tokenSelection = context
        if sheetDictionaryPanelEnabled {
            sheetSelection = context
        }
        pendingSelectionRange = nil
    }

    private static func recomputeFurigana(
        text: String,
        showFurigana: Bool,
        needsTokenHighlights: Bool,
        isEditing: Bool,
        textSize: Double,
        furiganaSize: Double,
        recomputeSpans: Bool,
        existingSpans: [AnnotatedSpan]?,
        overrides: [ReadingOverride],
        update: @escaping ([AnnotatedSpan]?, NSAttributedString?) -> Void
    ) async {
        guard showFurigana || needsTokenHighlights else {
            logFurigana("Aborting recompute: no consumers require annotated spans.")
            await MainActor.run { update(existingSpans, nil) }
            return
        }
        guard isEditing == false else {
            logFurigana("Aborting recompute: editor is in edit mode.")
            await MainActor.run { update(existingSpans, nil) }
            return
        }
        guard text.isEmpty == false else {
            logFurigana("Aborting recompute: paste text is empty.")
            await MainActor.run { update(nil, nil) }
            return
        }

        logFurigana("Starting furigana recompute for text length \(text.count). Recompute spans: \(recomputeSpans ? "yes" : "no").")
        if Task.isCancelled { return }

        var spans = existingSpans
        if recomputeSpans || spans == nil {
            do {
                spans = try await FuriganaAttributedTextBuilder.computeAnnotatedSpans(
                    text: text,
                    context: "PasteView",
                    overrides: overrides
                )
            } catch {
                logFurigana("Span computation failed: \(String(describing: error)).")
                return
            }
        }

        guard let readySpans = spans else {
            logFurigana("No spans available after recompute; returning plain text.")
            await MainActor.run { update(nil, NSAttributedString(string: text)) }
            return
        }

        let attributed = FuriganaAttributedTextBuilder.project(
            text: text,
            annotatedSpans: readySpans,
            textSize: textSize,
            furiganaSize: furiganaSize,
            context: "PasteView"
        )
        logFurigana("Furigana projection succeeded with length \(attributed.length).")
        await MainActor.run { update(readySpans, attributed) }
    }

    private static func logFurigana(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        let functionName = String(describing: function).replacingOccurrences(of: ":", with: " ")
        furiganaLogger.info("\(file) \(line) \(functionName) \(message, privacy: .public)")
    }
}

private enum MergeDirection {
    case previous
    case next
}

struct TokenSelectionContext: Equatable {
    let spanIndex: Int
    let range: NSRange
    let surface: String
    let annotatedSpan: AnnotatedSpan
}

extension TokenSelectionContext: Identifiable {
    var id: String { "\(spanIndex)-\(range.location)-\(range.length)" }
}

private final class OverrideUndoToken: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func perform() {
        action()
    }
}

private struct ControlCell<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }
}

private struct EditorContainer: View {
    @Binding var text: String
    var furiganaText: NSAttributedString?
    var furiganaSpans: [AnnotatedSpan]?
    var textSize: Double
    var isEditing: Bool
    var showFurigana: Bool
    var lineSpacing: Double
    var alternateTokenColors: Bool
    var highlightUnknownTokens: Bool
    var tokenPalette: [UIColor]
    var unknownTokenColor: UIColor
    var selectedRangeHighlight: NSRange?
    var customizedRanges: [NSRange]
    var onTokenSelection: ((RubyText.SelectionPayload) -> Void)? = nil
    var onSelectionCleared: (() -> Void)? = nil
    var title: Binding<String>? = nil

    private let placeholder = "Paste or type Japanese text"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isEditing {
                editorContent
            }
            else if text.isEmpty {
                displayShell {
                    EmptyView()
                }
            }
            else if showFurigana {
                displayShell {
                    rubyBlock(annotationVisibility: .visible)
                        .fixedSize(horizontal: false, vertical: true) // prevent vertical compression
                }
            }
            else {
                displayShell {
                    rubyBlock(annotationVisibility: .removed)
                }
            }
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color(.systemBackground))
        .cornerRadius(12)
    }

    private var editorContent: some View {
        VStack(spacing: 0) {
            if let titleBinding = title, isEditing {
                TextField("Title", text: titleBinding)
                    .font(.headline)
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                Divider()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            TextEditor(text: $text)
                .font(.system(size: textSize))
                .lineSpacing(lineSpacing)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .foregroundColor(.primary)
                .padding(editorInsets)
        }
    }

    private var editorInsets: EdgeInsets {
        let rubyHeadroom = max(0.0, textSize * 0.6 + lineSpacing)
        let baseTop = max(8.0, rubyHeadroom)
        let topInset = hasTitleField ? 8.0 : baseTop
        return EdgeInsets(top: CGFloat(topInset), leading: 11, bottom: 12, trailing: 12)
    }

    private var hasTitleField: Bool {
        title != nil && isEditing
    }

    private func displayShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                content()
                    .padding(8)
            }
            .font(.system(size: textSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rubyBlock(annotationVisibility: RubyAnnotationVisibility) -> some View {
        RubyText(
            attributed: resolvedAttributedText,
            fontSize: CGFloat(textSize),
            lineHeightMultiple: 1.0,
            extraGap: CGFloat(max(0, lineSpacing)),
            annotationVisibility: annotationVisibility,
            tokenOverlays: tokenColorOverlays,
            annotatedSpans: furiganaSpans ?? [],
                selectedRange: selectedRangeHighlight,
                customizedRanges: customizedRanges,
            onTokenSelection: onTokenSelection,
            onSelectionCleared: onSelectionCleared
        )
    }

    private var resolvedAttributedText: NSAttributedString {
        furiganaText ?? NSAttributedString(string: text)
    }

    private var tokenColorOverlays: [RubyText.TokenOverlay] {
        guard let spans = furiganaSpans, (alternateTokenColors || highlightUnknownTokens) else { return [] }
        let backingString = furiganaText?.string ?? text
        let textStorage = backingString as NSString
        var overlays: [RubyText.TokenOverlay] = []

        if alternateTokenColors {
            let palette = tokenPalette.filter { $0.cgColor.alpha > 0 }
            if palette.isEmpty == false {
                let coverageRanges = Self.coverageRanges(from: spans, textStorage: textStorage)
                overlays.reserveCapacity(coverageRanges.count)
                for (index, range) in coverageRanges.enumerated() {
                    let color = palette[index % palette.count]
                    overlays.append(RubyText.TokenOverlay(range: range, color: color))
                }
            }
        }

        if highlightUnknownTokens {
            let unknowns = Self.unknownTokenOverlays(from: spans, textStorage: textStorage, color: unknownTokenColor)
            overlays.append(contentsOf: unknowns)
        }

        return overlays
    }

    private static func coverageRanges(from spans: [AnnotatedSpan], textStorage: NSString) -> [NSRange] {
        let textLength = textStorage.length
        guard textLength > 0 else { return [] }
        let bounds = NSRange(location: 0, length: textLength)
        let sorted = spans
            .map { $0.span.range }
            .filter { $0.location != NSNotFound && $0.length > 0 }
            .map { NSIntersectionRange($0, bounds) }
            .filter { $0.length > 0 }
            .sorted { $0.location < $1.location }

        var ranges: [NSRange] = []
        ranges.reserveCapacity(sorted.count + 4)
        var cursor = 0
        for range in sorted {
            if range.location > cursor {
                let gap = NSRange(location: cursor, length: range.location - cursor)
                if containsNonWhitespace(in: gap, textStorage: textStorage) {
                    ranges.append(gap)
                }
            }
            ranges.append(range)
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < textLength {
            let trailing = NSRange(location: cursor, length: textLength - cursor)
            if containsNonWhitespace(in: trailing, textStorage: textStorage) {
                ranges.append(trailing)
            }
        }
        return ranges
    }

    private static func containsNonWhitespace(in range: NSRange, textStorage: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let substring = textStorage.substring(with: range)
        return substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    
    private static func clampRange(_ range: NSRange, length: Int) -> NSRange? {
        guard length > 0 else { return nil }
        let bounds = NSRange(location: 0, length: length)
        let clamped = NSIntersectionRange(range, bounds)
        return clamped.length > 0 ? clamped : nil
    }

    private static func unknownTokenOverlays(from spans: [AnnotatedSpan], textStorage: NSString, color: UIColor) -> [RubyText.TokenOverlay] {
        guard textStorage.length > 0 else { return [] }
        var overlays: [RubyText.TokenOverlay] = []
        overlays.reserveCapacity(spans.count)
        for span in spans where span.readingKana == nil {
            guard let clamped = Self.clampRange(span.span.range, length: textStorage.length) else { continue }
            if containsNonWhitespace(in: clamped, textStorage: textStorage) == false { continue }
            overlays.append(RubyText.TokenOverlay(range: clamped, color: color))
        }
        return overlays
    }
}

extension PasteView {
    static func createNewNote(notes: NotesStore, router: AppRouter) {
        notes.addNote(title: nil, text: "")
        notes.save()
        router.noteToOpen = notes.notes.first ?? notes.notes.last
        router.pasteShouldBeginEditing = true
        router.selectedTab = .paste
        PasteBufferStore.save("")
    }
}

