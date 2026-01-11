import SwiftUI
import UIKit
import Foundation

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
    @EnvironmentObject var tokenBoundaries: TokenBoundariesStore
    @Environment(\.undoManager) private var undoManager

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var noteTitleInput: String = ""
    @State private var hasManuallyEditedTitle: Bool = false
    @State private var hasInitialized: Bool = false
    @State private var isEditing: Bool = false
    @State private var furiganaAttributedText: NSAttributedString? = nil
    @State private var furiganaSpans: [AnnotatedSpan]? = nil
    @State private var furiganaSemanticSpans: [SemanticSpan] = []
    @State private var furiganaRefreshToken: Int = 0
    @State private var furiganaTaskHandle: Task<Void, Never>? = nil
    @StateObject private var inlineLookup = DictionaryLookupViewModel()
    @StateObject private var selectionController = TokenSelectionController()
    @State private var overrideSignature: Int = 0
    @State private var customizedRanges: [NSRange] = []
    @State private var showTokensPopover: Bool = false
    @State private var showAdjustedSpansPopover: Bool = false
    @State private var pendingRouterResetNoteID: UUID? = nil
    @State private var skipNextInitialFuriganaEnsure: Bool = false
    @State private var isDictionarySheetPresented: Bool = false
    @State private var measuredSheetHeight: CGFloat = 0

    // Incremental lookup (tap character → lookup n, n+n1, ..., up to next newline)
    @State private var incrementalPopupHits: [IncrementalLookupHit] = []
    @State private var isIncrementalPopupVisible: Bool = false
    @State private var incrementalLookupTask: Task<Void, Never>? = nil
    @State private var savedWordOverlays: [RubyText.TokenOverlay] = []
    @State private var incrementalSelectedCharacterRange: NSRange? = nil
    @State private var incrementalSheetDetent: PresentationDetent = .height(420)

    @State private var showWordDefinitionsSheet: Bool = false
    @State private var wordDefinitionsSurface: String = ""
    @State private var wordDefinitionsKana: String? = nil

    private var tokenSelection: TokenSelectionContext? {
        get { selectionController.tokenSelection }
        nonmutating set { selectionController.tokenSelection = newValue }
    }

    private var persistentSelectionRange: NSRange? {
        get { selectionController.persistentSelectionRange }
        nonmutating set { selectionController.persistentSelectionRange = newValue }
    }

    private var sheetSelection: TokenSelectionContext? {
        get { selectionController.sheetSelection }
        nonmutating set { selectionController.sheetSelection = newValue }
    }

    private var sheetPanelHeight: CGFloat {
        get { selectionController.sheetPanelHeight }
        nonmutating set { selectionController.sheetPanelHeight = newValue }
    }

    private var pendingSelectionRange: NSRange? {
        get { selectionController.pendingSelectionRange }
        nonmutating set { selectionController.pendingSelectionRange = newValue }
    }

    private var pendingSplitFocusSelectionID: String? {
        get { selectionController.pendingSplitFocusSelectionID }
        nonmutating set { selectionController.pendingSplitFocusSelectionID = newValue }
    }

    private var tokenPanelFrame: CGRect? {
        get { selectionController.tokenPanelFrame }
        nonmutating set { selectionController.tokenPanelFrame = newValue }
    }

    private var inlineContextMenuState: RubyContextMenuState? {
        guard let selection = tokenSelection else { return nil }
        return RubyContextMenuState(
            canMergeLeft: canMergeSelection(.previous),
            canMergeRight: canMergeSelection(.next),
            canSplit: selection.range.length > 1
        )
    }

    @AppStorage("readingTextSize") private var readingTextSize: Double = 17
    @AppStorage("readingFuriganaSize") private var readingFuriganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var readingLineSpacing: Double = 4
    @AppStorage("readingShowFurigana") private var showFurigana: Bool = true
    @AppStorage("readingWrapLines") private var wrapLines: Bool = false
    @AppStorage("readingAlternateTokenColors") private var alternateTokenColors: Bool = false
    @AppStorage("readingHighlightUnknownTokens") private var highlightUnknownTokens: Bool = false
    @AppStorage("readingAlternateTokenColorA") private var alternateTokenColorAHex: String = "#0A84FF"
    @AppStorage("readingAlternateTokenColorB") private var alternateTokenColorBHex: String = "#FF2D55"
    @AppStorage("pasteViewScratchNoteID") private var scratchNoteIDRaw: String = ""
    @AppStorage("pasteViewLastOpenedNoteID") private var lastOpenedNoteIDRaw: String = ""
    @AppStorage("extractHideDuplicateTokens") private var hideDuplicateTokens: Bool = false
    @AppStorage("extractHideCommonParticles") private var hideCommonParticles: Bool = false
    @AppStorage(CommonParticleSettings.storageKey) private var commonParticlesRaw: String = CommonParticleSettings.defaultRawValue

    private var scratchNoteID: UUID {
        if let cached = UUID(uuidString: scratchNoteIDRaw) {
            return cached
        }
        let newID = UUID()
        scratchNoteIDRaw = newID.uuidString
        return newID
    }

    private var lastOpenedNoteID: UUID? {
        guard lastOpenedNoteIDRaw.isEmpty == false else { return nil }
        return UUID(uuidString: lastOpenedNoteIDRaw)
    }

    
    private static let coordinateSpaceName = "PasteViewRootSpace"
    private static let inlineDictionaryPanelEnabledFlag = true
    private static let dictionaryPopupEnabledFlag = true // Tap in paste area shows popup + highlight.
    private static let incrementalLookupEnabledFlag = false
    private static let sheetMaxHeightFraction: CGFloat = 0.8
    private static let sheetExtraPadding: CGFloat = 36
    private let furiganaPipeline = FuriganaPipelineService()
    private var incrementalLookupEnabled: Bool { Self.incrementalLookupEnabledFlag }
    private var dictionaryPopupEnabled: Bool { Self.dictionaryPopupEnabledFlag && incrementalLookupEnabled == false }
    private var inlineDictionaryPanelEnabled: Bool { Self.inlineDictionaryPanelEnabledFlag && dictionaryPopupEnabled }
    private var sheetDictionaryPanelEnabled: Bool { dictionaryPopupEnabled && inlineDictionaryPanelEnabled == false }
    private var pasteAreaDictionaryEnabled: Bool { false }
    private var tokenSpansAlwaysOn: Bool { true }
    private var spanConsumersActive: Bool { showFurigana || tokenHighlightsEnabled || tokenSpansAlwaysOn }
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
    private var tokenHighlightsEnabled: Bool {
        guard incrementalLookupEnabled == false else { return false }
        return alternateTokenColors || highlightUnknownTokens
    }
    private var sheetSelectionBinding: Binding<TokenSelectionContext?> {
        Binding(
            // The Extract Words sheet relies on this binding to display the in-sheet
            // dictionary popup. Do not nil it out while the sheet is presented.
            get: { sheetSelection },
            set: { sheetSelection = $0 }
        )
    }
    private var commonParticleSet: Set<String> {
        Set(CommonParticleSettings.decodeList(from: commonParticlesRaw))
    }

    private var navigationTitleText: String {
        noteTitleInput.isEmpty ? "Paste" : noteTitleInput
    }

    var body: some View {
        NavigationStack {
            applyDictionarySheet(to: coreContent)
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(TokenActionPanelFramePreferenceKey.self) { newValue in
            tokenPanelFrame = newValue
        }
        .sheet(isPresented: $showWordDefinitionsSheet) {
            NavigationStack {
                WordDefinitionsView(
                    surface: wordDefinitionsSurface,
                    kana: wordDefinitionsKana,
                    sourceNoteID: currentNote?.id
                )
            }
        }
        .sheet(isPresented: $isIncrementalPopupVisible, onDismiss: {
            dismissIncrementalLookupSheet()
        }) {
            incrementalLookupSheet
                .presentationDetents(incrementalSheetDetents, selection: $incrementalSheetDetent)
                .presentationDragIndicator(.visible)
        }
    }

    private var coreContent: some View {
        let base = coreStack
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { coreToolbar }
            .safeAreaInset(edge: .bottom) { coreBottomInset }
            .onAppear { onAppearHandler() }
            .onDisappear {
                NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
                furiganaTaskHandle?.cancel()
            }

        return base
            .onChange(of: inputText) { _, newValue in
                skipNextInitialFuriganaEnsure = false
                clearSelection()
                if incrementalLookupEnabled {
                    incrementalLookupTask?.cancel()
                    isIncrementalPopupVisible = false
                    incrementalPopupHits = []
                    incrementalSelectedCharacterRange = nil
                    recomputeSavedWordOverlays()
                }
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
                }
            }

            .onChange(of: words.words.count) {
                guard incrementalLookupEnabled else { return }
                recomputeSavedWordOverlays()
            }
            .onChange(of: showFurigana) { _, enabled in
                if enabled {
                    triggerFuriganaRefreshIfNeeded(reason: "show furigana toggled on", recomputeSpans: true)
                } else {
                    furiganaTaskHandle?.cancel()
                }
            }
            .onChange(of: alternateTokenColors) { _, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "alternate token colors toggled on" : "alternate token colors toggled off",
                    recomputeSpans: false
                )
            }
            .onChange(of: highlightUnknownTokens) { _, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "unknown highlight toggled on" : "unknown highlight toggled off",
                    recomputeSpans: false
                )
            }
            .onChange(of: readingFuriganaSize) {
                triggerFuriganaRefreshIfNeeded(reason: "furigana font size changed", recomputeSpans: false)
            }
            .onChange(of: selectionController.tokenSelection?.id) { (_: String?, newID: String?) in
                let newSelection = selectionController.tokenSelection
                if newSelection == nil {
                    if isDictionarySheetPresented {
                        isDictionarySheetPresented = false
                    }
                    // Also clear the token panel frame when selection is cleared.
                    tokenPanelFrame = nil
                }
                if dictionaryPopupEnabled {
                    if let _ = newID {
                        if let ctx = newSelection {
                            let r = ctx.range
                            CustomLogger.shared.debug("Dictionary popup shown (selection change) tokenIndex=\(ctx.tokenIndex) range=\(r.location)-\(NSMaxRange(r)) surface=\(ctx.surface) inline=\(self.inlineDictionaryPanelEnabled) sheet=\(self.sheetDictionaryPanelEnabled)")
                        } else {
                            CustomLogger.shared.debug("Dictionary popup shown (selection change)")
                        }
                    } else {
                        CustomLogger.shared.debug("Dictionary popup hidden (selection cleared)")
                    }
                }
                handleSelectionLookup(for: newSelection?.surface ?? "")
            }
            .onChange(of: sheetSelection?.id) { (_: String?, newID: String?) in
                guard dictionaryPopupEnabled else { return }
                if let _ = newID {
                    if let ctx = sheetSelection {
                        let r = ctx.range
                        CustomLogger.shared.debug("Dictionary popup shown (sheet binding) tokenIndex=\(ctx.tokenIndex) range=\(r.location)-\(NSMaxRange(r)) surface=\(ctx.surface)")
                    } else {
                        CustomLogger.shared.debug("Dictionary popup shown (sheet binding)")
                    }
                } else {
                    CustomLogger.shared.debug("Dictionary popup hidden (sheet binding cleared)")
                }
            }
            .onChange(of: currentNote?.id) { _, newValue in
                lastOpenedNoteIDRaw = newValue?.uuidString ?? ""
                clearSelection()
                overrideSignature = computeOverrideSignature()
                updateCustomizedRanges()
                if incrementalLookupEnabled {
                    incrementalLookupTask?.cancel()
                    isIncrementalPopupVisible = false
                    incrementalPopupHits = []
                    incrementalSelectedCharacterRange = nil
                    recomputeSavedWordOverlays()
                }
                processPendingRouterResetRequest()
            }
            .onReceive(readingOverrides.$overrides) { _ in
                handleOverridesExternalChange()
            }
            .onChange(of: router.pendingResetNoteID) { _, newValue in
                pendingRouterResetNoteID = newValue
                processPendingRouterResetRequest()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isDictionarySheetPresented {
                    isDictionarySheetPresented = false
                    clearSelection(resetPersistent: true)
                }
            }
    }

    private var coreStack: some View {
        ZStack(alignment: .bottom) {
            editorColumn
            inlineDictionaryOverlay
        }
    }

    private var editorColumn: some View {
        // Precompute helpers outside of the ViewBuilder to avoid non-View statements inside VStack
        let extraOverlays: [RubyText.TokenOverlay] = incrementalLookupEnabled ? savedWordOverlays : []

        let spanSelectionHandler: ((RubySpanSelection?) -> Void)?
        if incrementalLookupEnabled {
            spanSelectionHandler = nil
        } else {
            spanSelectionHandler = { selection in
                handleInlineSpanSelection(selection)
            }
        }

        let contextMenuStateProvider: (() -> RubyContextMenuState?)?
        if incrementalLookupEnabled {
            contextMenuStateProvider = nil
        } else {
            contextMenuStateProvider = {
                inlineContextMenuState
            }
        }

        let contextMenuActionHandler: ((RubyContextMenuAction) -> Void)?
        if incrementalLookupEnabled {
            contextMenuActionHandler = nil
        } else {
            contextMenuActionHandler = { action in
                handleContextMenuAction(action)
            }
        }

        return VStack(spacing: 0) {
            FuriganaRenderingHost(
                text: $inputText,
                furiganaText: furiganaAttributedText,
                furiganaSpans: furiganaSpans,
                semanticSpans: furiganaSemanticSpans,
                textSize: readingTextSize,
                isEditing: isEditing,
                showFurigana: incrementalLookupEnabled ? false : showFurigana,
                lineSpacing: readingLineSpacing,
                wrapLines: wrapLines,
                alternateTokenColors: incrementalLookupEnabled ? false : alternateTokenColors,
                highlightUnknownTokens: incrementalLookupEnabled ? false : highlightUnknownTokens,
                tokenPalette: alternateTokenPalette,
                unknownTokenColor: unknownTokenColor,
                selectedRangeHighlight: incrementalLookupEnabled ? incrementalSelectedCharacterRange : persistentSelectionRange,
                customizedRanges: customizedRanges,
                extraTokenOverlays: extraOverlays,
                enableTapInspection: true,
                onCharacterTap: { utf16Index in
                    if incrementalLookupEnabled {
                            // Existing incremental lookup behavior
                        let ns = inputText as NSString
                        if ns.length == 0 {
                            incrementalSelectedCharacterRange = nil
                        } else {
                            let clamped = min(max(0, utf16Index), max(0, ns.length - 1))
                            let r = ns.rangeOfComposedCharacterSequence(at: clamped)
                            let ch = ns.substring(with: r)
                            if ch == "\n" || ch == "\r" {
                                incrementalSelectedCharacterRange = nil
                                incrementalLookupTask?.cancel()
                                isIncrementalPopupVisible = false
                                incrementalPopupHits = []
                                return
                            }
                            incrementalSelectedCharacterRange = r
                        }
                        startIncrementalLookup(atUTF16Index: utf16Index)
                    } else {
                            // Fallback: map tap position to the semantic span containing the tapped UTF-16 index
                        let ns = inputText as NSString
                        guard ns.length > 0 else { return }
                        let clamped = min(max(0, utf16Index), max(0, ns.length - 1))
                        let r = ns.rangeOfComposedCharacterSequence(at: clamped)
                        let ch = ns.substring(with: r)
                        if ch == "\n" || ch == "\r" {
                            clearSelection()
                            return
                        }
                        if let match = furiganaSemanticSpans.enumerated().first(where: { NSLocationInRange(clamped, $0.element.range) }) {
                            let surface = ns.substring(with: match.element.range)
                            if surface.contains("ロン") || surface.contains("ハ") {
                                let scalars = surface.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ")
                                CustomLogger.shared.print("[TAP PROBE] surface=\(surface) utf16Len=\(surface.utf16.count) scalars=\(scalars)")
                            }
                            presentDictionaryForSpan(at: match.offset, focusSplitMenu: false)
                        } else {
                                // No token at this location; clear selection
                            clearSelection()
                        }
                    }
                }, onSpanSelection: spanSelectionHandler, enableDragSelection: incrementalLookupEnabled ? false : (alternateTokenColors == false),
                onDragSelectionBegan: {
                    guard incrementalLookupEnabled == false else { return }
                        // Avoid showing stale popup content while the user is selecting.
                    clearSelection(resetPersistent: true)
                },
                onDragSelectionEnded: { range in
                    guard incrementalLookupEnabled == false else { return }
                    guard alternateTokenColors == false else { return }
                    presentDictionaryForArbitraryRange(range)
                },
                contextMenuStateProvider: contextMenuStateProvider,
                onContextMenuAction: contextMenuActionHandler
            )
            .padding(.vertical, 16)

            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            HStack(alignment: .center, spacing: 0) {
                ControlCell {
                    Button { hideKeyboard() } label: {
                        Image(systemName: "keyboard.chevron.compact.down").font(.title2)
                    }
                    .accessibilityLabel("Hide Keyboard")
                }

                ControlCell {
                    Button(action: pasteFromClipboard) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.title2)
                    }
                    .accessibilityLabel("Paste")
                }

                ControlCell {
                    Button(action: saveNote) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.title2)
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
                    Toggle(isOn: $wrapLines) {
                        Label("Wrap Lines", systemImage: "text.justify")
                    }
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
    }

    private var transformPasteTextButton: some View {
        Button {
            let transformed = PasteTextTransforms.transform(inputText)
            if transformed != inputText {
                inputText = transformed
            }
        } label: {
            Image(systemName: "wand.and.stars")
        }
        .accessibilityLabel("Transform Paste Text")
    }

    private var resetSpansButton: some View {
        Button {
            resetAllCustomSpans()
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .accessibilityLabel("Reset Spans")
    }

    private var adjustedSpansButton: some View {
        Button {
            showAdjustedSpansPopover = true
        } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel("Show Adjusted Spans")
        .popover(isPresented: $showAdjustedSpansPopover) {
            ScrollView {
                Text(adjustedSpansDebugText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var adjustedSpansDebugText: String {
        guard let spans = furiganaSpans, spans.isEmpty == false else {
            return "(No spans yet)"
        }
        return SegmentationService.describe(spans: spans.map(\.span))
    }

    private var tokenListButton: some View {
        Button {
            showTokensPopover = true
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .accessibilityLabel("Extract Words")
        .sheet(isPresented: $showTokensPopover) {
            tokenListSheet
                .presentationDetents(Set([.large]))
                .presentationDragIndicator(.visible)
        }
    }

    private var tokenListSheet: some View {
        NavigationStack {
            ExtractWordsView(
                items: tokenListItems,
                isReady: (furiganaSemanticSpans.isEmpty == false) || (furiganaSpans != nil),
                isEditing: isEditing,
                selectedRange: tokenSelection?.range ?? persistentSelectionRange,
                hideDuplicateTokens: $hideDuplicateTokens,
                hideCommonParticles: $hideCommonParticles,
                onSelect: { presentDictionaryForSpan(at: $0, focusSplitMenu: false) },
                onGoTo: { goToSpanInNote(at: $0) },
                onAdd: { bookmarkToken(at: $0) },
                onMergeLeft: { mergeSpan(at: $0, direction: .previous) },
                onMergeRight: { mergeSpan(at: $0, direction: .next) },
                onSplit: { startSplitFlow(for: $0) },
                canMergeLeft: { canMergeSpan(at: $0, direction: .previous) },
                canMergeRight: { canMergeSpan(at: $0, direction: .next) },
                sheetSelection: sheetSelectionBinding,
                dictionaryPanel: { selection in
                    dictionaryPanel(for: selection, enableDragToDismiss: true, embedInMaterialBackground: true)
                },
                onDone: { showTokensPopover = false }
            )
        }
    }

    private var tokenListItems: [TokenListItem] {
        guard furiganaSemanticSpans.isEmpty == false else { return [] }
        let noteID = currentNote?.id

        var items: [TokenListItem] = []
        items.reserveCapacity(furiganaSemanticSpans.count)

        var seenKeys: Set<String> = []
        for (index, semantic) in furiganaSemanticSpans.enumerated() {
            guard let trimmed = trimmedRangeAndSurface(for: semantic.range) else { continue }
            let surface = trimmed.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard surface.isEmpty == false else { continue }

            if hideCommonParticles, commonParticleSet.contains(surface) {
                continue
            }

            let reading = normalizedReading(semantic.readingKana)
            let key = "\(surface)|\(reading ?? "")"
            if hideDuplicateTokens, seenKeys.contains(key) {
                continue
            }
            seenKeys.insert(key)

            let displayReading = readingWithOkurigana(surface: surface, baseReading: reading)
            let alreadySaved = hasSavedWord(surface: surface, reading: reading, noteID: noteID)
            items.append(
                TokenListItem(
                    spanIndex: index,
                    range: trimmed.range,
                    surface: surface,
                    reading: reading,
                    displayReading: displayReading,
                    isAlreadySaved: alreadySaved
                )
            )
        }

        return items
    }

    @ToolbarContentBuilder
    private var coreToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            adjustedSpansButton
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                transformPasteTextButton
                resetSpansButton
                tokenListButton
            }
        }
    }

    @ViewBuilder
    private var coreBottomInset: some View {
        if selectionController.tokenSelection == nil {
            Color.clear.frame(height: 24)
        }
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

    @ViewBuilder
    private var incrementalLookupOverlay: some View { EmptyView() }

    private var incrementalSheetDetents: Set<PresentationDetent> {
        Set([.height(300), .height(420), .height(560), .large])
    }

    private var incrementalPreferredSheetDetent: PresentationDetent {
        let groupCount = incrementalPopupGroups.count
        if groupCount <= 1 {
            return .height(300)
        } else if groupCount <= 3 {
            return .height(420)
        } else {
            return .height(560)
        }
    }

    private func dismissIncrementalLookupSheet() {
        incrementalLookupTask?.cancel()
        incrementalPopupHits = []
        incrementalSelectedCharacterRange = nil
    }

    private func inlineTokenActionPanel(for selection: TokenSelectionContext) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            TokenActionPanel(
                selection: selection,
                lookup: inlineLookup,
                preferredReading: preferredReadingForSelection(selection),
                canMergePrevious: canMergeSelection(.previous),
                canMergeNext: canMergeSelection(.next),
                onDismiss: { clearSelection(resetPersistent: false) },
                onSaveWord: { entry in
                    toggleSavedWord(surface: selection.surface, entry: entry)
                },
                onApplyReading: { entry in
                    applyDictionaryReading(entry)
                },
                onApplyCustomReading: { kana in
                    applyCustomReading(kana)
                },
                isWordSaved: { entry in
                    isSavedWord(for: selection.surface, entry: entry)
                },
                onMergePrevious: { mergeSelection(.previous) },
                onMergeNext: { mergeSelection(.next) },
                onSplit: { offset in splitSelection(at: offset) },
                onReset: resetSelectionOverrides,
                isSelectionCustomized: selectionIsCustomized(selection),
                enableDragToDismiss: true,
                embedInMaterialBackground: true,
                focusSplitMenu: pendingSplitFocusSelectionID == selection.id,
                onSplitFocusConsumed: { pendingSplitFocusSelectionID = nil }
            )
            .id("\(selection.id)-\(overrideSignature)")
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
        furiganaSemanticSpans = []
    }

    private func onAppearHandler() {
        if let note = router.noteToOpen {
            currentNote = note
            assignInputTextFromExternalSource(note.text)
            noteTitleInput = note.title ?? ""
            hasManuallyEditedTitle = (note.title?.isEmpty == false)
            if router.pasteShouldBeginEditing {
                setEditing(true)
            }
            else {
                setEditing(false)
            }
            router.pasteShouldBeginEditing = false
            router.noteToOpen = nil
        } else if currentNote == nil,
                  inputText.isEmpty,
                  let lastID = lastOpenedNoteID,
                  let note = notes.notes.first(where: { $0.id == lastID }) {
            currentNote = note
            assignInputTextFromExternalSource(note.text)
            noteTitleInput = note.title ?? ""
            hasManuallyEditedTitle = (note.title?.isEmpty == false)
            setEditing(false)
        } else if let existingNote = currentNote, noteTitleInput.isEmpty {
            noteTitleInput = existingNote.title ?? ""
            hasManuallyEditedTitle = (existingNote.title?.isEmpty == false)
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
                assignInputTextFromExternalSource(persisted)
                setEditing(false)
            }
            noteTitleInput = ""
            hasManuallyEditedTitle = false
        }
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        migrateBoundaryOverridesIfNeeded()
        pendingRouterResetNoteID = router.pendingResetNoteID
        processPendingRouterResetRequest()

        if incrementalLookupEnabled {
            // New paste strategy: furigana + token highlighting disabled (pipeline remains).
            if showFurigana {
                showFurigana = false
            }
            if alternateTokenColors {
                alternateTokenColors = false
            }
            if highlightUnknownTokens {
                highlightUnknownTokens = false
            }
            incrementalLookupTask?.cancel()
            isIncrementalPopupVisible = false
            incrementalPopupHits = []
            recomputeSavedWordOverlays()
        }

        ensureInitialFuriganaReady(reason: "onAppear initialization")
    }

    private func migrateBoundaryOverridesIfNeeded() {
        let noteID = activeNoteID
        let boundaryOverrides = readingOverrides.overrides(for: noteID).filter { $0.userKana == nil }
        if tokenBoundaries.hasCustomSpans(for: noteID) {
            if boundaryOverrides.isEmpty == false {
                readingOverrides.removeBoundaryOverrides(for: noteID)
                overrideSignature = computeOverrideSignature()
                updateCustomizedRanges()
            }
            return
        }
        guard boundaryOverrides.isEmpty == false else { return }
        guard inputText.isEmpty == false else { return }

        Task {
            let text = inputText
            let nsText = text as NSString
            let length = nsText.length
            guard length > 0 else { return }
            do {
                let base = try await SegmentationService.shared.segment(text: text)
                let overrideSpans: [TextSpan] = boundaryOverrides.compactMap { override in
                    let r = override.nsRange
                    guard r.location != NSNotFound, r.length > 0 else { return nil }
                    guard r.location < length else { return nil }
                    let end = min(NSMaxRange(r), length)
                    guard end > r.location else { return nil }
                    let range = NSRange(location: r.location, length: end - r.location)
                    let surface = nsText.substring(with: range)
                    return TextSpan(range: range, surface: surface, isLexiconMatch: false)
                }
                guard overrideSpans.isEmpty == false else { return }
                let overrideRanges = overrideSpans.map(\.range)
                var amended = base.filter { baseSpan in
                    overrideRanges.contains { NSIntersectionRange($0, baseSpan.range).length > 0 } == false
                }
                amended.append(contentsOf: overrideSpans)
                amended.sort { lhs, rhs in
                    if lhs.range.location == rhs.range.location { return lhs.range.length < rhs.range.length }
                    return lhs.range.location < rhs.range.location
                }
                await MainActor.run {
                    tokenBoundaries.setSpans(noteID: noteID, spans: amended, text: text)
                    readingOverrides.removeBoundaryOverrides(for: noteID)
                    overrideSignature = computeOverrideSignature()
                    updateCustomizedRanges()
                    triggerFuriganaRefreshIfNeeded(reason: "migrated legacy token edits", recomputeSpans: true)
                }
            } catch {
                return
            }
        }
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
        CustomLogger.shared.debug("Clearing selection resetPersistent=\(resetPersistent)")
        let hadSelection = selectionController.tokenSelection != nil
        selectionController.clearSelection(resetPersistent: resetPersistent)
        isDictionarySheetPresented = false
        Task { @MainActor in
            inlineLookup.results = []
            inlineLookup.errorMessage = nil
            inlineLookup.isLoading = false
        }
        if dictionaryPopupEnabled && hadSelection {
            CustomLogger.shared.debug("Dictionary popup hidden")
        }
    }

    private func handleInlineSpanSelection(_ selection: RubySpanSelection?) {
        guard let selection else {
            clearSelection()
            return
        }

        ivlog("Tap.handleInlineSpanSelection tokenIndex=\(selection.tokenIndex) highlight=\(selection.highlightRange.location)-\(NSMaxRange(selection.highlightRange))")

        // INVESTIGATION NOTES (2026-01-04)
        // Token tap → dictionary popup execution path:
        // RubyText.TokenOverlayTextView.handleInspectionTap → spanSelectionHandler → PasteView.handleInlineSpanSelection
        // → presentDictionaryForSpan(at:) → selectionContext(forSpanAt:) → aggregatedAnnotatedSpan(for:) (lemma + POS aggregation)
        // → TokenActionPanel + DictionaryLookupViewModel.load(term:fallbackTerms:).
        //
        // Potential jitter sources on tap:
        // - `selectionContext(forSpanAt:)` rebuilds a TokenSelectionContext and aggregates lemma candidates.
        // - `handleSelectionLookup` can trigger multiple SQLite lookups (primary term + lemma fallbacks).
        presentDictionaryForSpan(at: selection.tokenIndex, focusSplitMenu: false)
        persistentSelectionRange = selection.highlightRange
    }



    private func handleContextMenuAction(_ action: RubyContextMenuAction) {
        switch action {
        case .mergeLeft:
            mergeSelection(.previous)
        case .mergeRight:
            mergeSelection(.next)
        case .split:
            focusSplitMenuForCurrentSelection()
        }
    }

    private func focusSplitMenuForCurrentSelection() {
        guard let selection = tokenSelection else { return }
        startSplitFlow(for: selection.tokenIndex)
    }

    private func presentDictionaryForArbitraryRange(_ rawRange: NSRange) {
        guard rawRange.location != NSNotFound, rawRange.length > 0 else {
            clearSelection()
            return
        }
        guard let trimmed = trimmedRangeAndSurface(for: rawRange) else {
            clearSelection()
            return
        }
        let surface = trimmed.surface
        guard surface.isEmpty == false else {
            clearSelection()
            return
        }

        let semantic = SemanticSpan(range: trimmed.range, surface: surface, sourceSpanIndices: 0..<0, readingKana: nil)
        let annotated = AnnotatedSpan(span: TextSpan(range: trimmed.range, surface: surface, isLexiconMatch: false), readingKana: nil, lemmaCandidates: [], partOfSpeech: nil)
        let ctx = TokenSelectionContext(
            tokenIndex: -1,
            range: trimmed.range,
            surface: surface,
            semanticSpan: semantic,
            sourceSpanIndices: 0..<0,
            annotatedSpan: annotated
        )

        pendingSelectionRange = nil
        persistentSelectionRange = trimmed.range
        tokenSelection = ctx
        pendingSplitFocusSelectionID = nil
    }

    @MainActor
    private func beginPendingSelectionRestoration(for range: NSRange) {
        selectionController.beginPendingSelectionRestoration(for: range)
    }

    private func handleSelectionLookup(for term: String) {
        // INVESTIGATION NOTES (2026-01-04)
        // Dictionary lookup behavior for the popup:
        // - Primary term is the selected surface.
        // - Fallback terms are lemma candidates (can be multiple).
        // DictionaryLookupViewModel.load iterates candidates sequentially and does SQLite lookups until hits.
        // This means one tap can cause multiple DB queries and result allocations.
        guard term.isEmpty == false else {
            Task { @MainActor in
                inlineLookup.results = []
                inlineLookup.errorMessage = nil
                inlineLookup.isLoading = false
            }
            return
        }
        let lemmaFallbacks = tokenSelection?.annotatedSpan.lemmaCandidates ?? []

        ivlog("Tap.handleSelectionLookup term='\(term)' fallbacks=\(lemmaFallbacks.count)")
        Task { [lemmaFallbacks] in
            await inlineLookup.load(term: term, fallbackTerms: lemmaFallbacks)
        }
    }

    private func dictionaryPanel(for selection: TokenSelectionContext, enableDragToDismiss: Bool, embedInMaterialBackground: Bool) -> TokenActionPanel {
        TokenActionPanel(
            selection: selection,
            lookup: inlineLookup,
            preferredReading: preferredReadingForSelection(selection),
            canMergePrevious: canMergeSelection(.previous),
            canMergeNext: canMergeSelection(.next),
            onShowDefinitions: {
                presentWordDefinitions(for: selection)
            },
            onDismiss: { clearSelection(resetPersistent: false) },
            onSaveWord: { entry in
                toggleSavedWord(surface: selection.surface, entry: entry)
            },
            onApplyReading: { entry in
                applyDictionaryReading(entry)
            },
            onApplyCustomReading: { kana in
                applyCustomReading(kana)
            },
            isWordSaved: { entry in
                isSavedWord(for: selection.surface, entry: entry)
            },
            onMergePrevious: { mergeSelection(.previous) },
            onMergeNext: { mergeSelection(.next) },
            onSplit: { offset in splitSelection(at: offset) },
            onReset: resetSelectionOverrides,
            isSelectionCustomized: selectionIsCustomized(selection),
            enableDragToDismiss: enableDragToDismiss,
            embedInMaterialBackground: embedInMaterialBackground,
            focusSplitMenu: pendingSplitFocusSelectionID == selection.id,
            onSplitFocusConsumed: { pendingSplitFocusSelectionID = nil }
        )
    }

    private func isSavedWord(for surface: String, entry: DictionaryEntry) -> Bool {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return false }
        let noteID = currentNote?.id
        let targetSurface = kanaFoldToHiragana(resolvedSurface(from: entry, fallback: s))
        let targetKana = kanaFoldToHiragana(kana)
        return words.words.contains { word in
            guard word.sourceNoteID == noteID else { return false }
            guard kanaFoldToHiragana(word.surface) == targetSurface else { return false }
            return kanaFoldToHiragana(word.kana) == targetKana
        }
    }

    private func toggleSavedWord(surface: String, entry: DictionaryEntry) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return }
        let noteID = currentNote?.id

        let targetSurface = kanaFoldToHiragana(resolvedSurface(from: entry, fallback: s))
        let targetKana = kanaFoldToHiragana(kana)

        let matchingIDs = Set(
            words.words
                .filter {
                    guard $0.sourceNoteID == noteID else { return false }
                    guard kanaFoldToHiragana($0.surface) == targetSurface else { return false }
                    return kanaFoldToHiragana($0.kana) == targetKana
                }
                .map(\.id)
        )

        if matchingIDs.isEmpty {
            let meaning = normalizedMeaning(from: entry.gloss)
            guard meaning.isEmpty == false else { return }
            let resolvedSurface = resolvedSurface(from: entry, fallback: s)
            let resolvedKana = normalizedReading(entry.kana)
            words.add(surface: resolvedSurface, kana: resolvedKana, meaning: meaning, note: nil, sourceNoteID: noteID)
        } else {
            words.delete(ids: matchingIDs)
        }
    }

    private func presentWordDefinitions(for selection: TokenSelectionContext) {
        wordDefinitionsSurface = selection.surface
        wordDefinitionsKana = normalizedReading(preferredReadingForSelection(selection))
        showWordDefinitionsSheet = true
    }

    private func preferredReadingForSelection(_ selection: TokenSelectionContext) -> String? {
        let overrides = readingOverrides.overrides(for: activeNoteID, overlapping: selection.range)
        if let exact = overrides.first(where: {
            $0.rangeStart == selection.range.location &&
            $0.rangeLength == selection.range.length &&
            $0.userKana != nil
        }) {
            return exact.userKana
        }

        if let bestOverlap = overrides
            .filter({ $0.userKana != nil })
            .max(by: { lhs, rhs in
                let lhsRange = NSRange(location: lhs.rangeStart, length: lhs.rangeLength)
                let rhsRange = NSRange(location: rhs.rangeStart, length: rhs.rangeLength)
                return NSIntersectionRange(lhsRange, selection.range).length < NSIntersectionRange(rhsRange, selection.range).length
            }) {
            return bestOverlap.userKana
        }

        return selection.annotatedSpan.readingKana
    }

    private func applyDictionarySheet<Content: View>(to view: Content) -> AnyView {
        if sheetDictionaryPanelEnabled {
            return AnyView(
                view.sheet(isPresented: $isDictionarySheetPresented, onDismiss: {
                    if dictionaryPopupEnabled {
                        CustomLogger.shared.debug("Dictionary popup dismissed by user")
                    }
                    clearSelection(resetPersistent: true)
                }) {
                    if let selection = sheetSelection {
                        let sheetPanel = dictionaryPanel(
                            for: selection,
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
                                measuredSheetHeight = newValue
                            }
                            .presentationDragIndicator(.visible)
                            .presentationDetents(Set([.height(max(sheetPanelHeight + 50, 300))]))
                            .presentationBackgroundInteraction(.enabled)
                    } else {
                        // If the selection is nil while presented, close the sheet.
                        EmptyView()
                            .onAppear { isDictionarySheetPresented = false }
                    }
                }
            )
        } else {
            return AnyView(view)
        }
    }

    private func preferredSheetDetentHeight() -> CGFloat {
        let screenHeight: CGFloat = {
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                if let keyWindow = scene.windows.first(where: { $0.isKeyWindow }) {
                    return keyWindow.bounds.height
                }
                if let firstWindow = scene.windows.first {
                    return firstWindow.bounds.height
                }
                if let screen = scene.screen as UIScreen? {
                    return screen.bounds.height
                }
            }
            return 480
        }()
        let fallback = screenHeight * 0.45
        guard sheetPanelHeight > 0 else { return fallback }
        let padded = sheetPanelHeight + Self.sheetExtraPadding
        let maxHeight = screenHeight * Self.sheetMaxHeightFraction
        let minHeight: CGFloat = 280
        return min(max(padded, minHeight), maxHeight)
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

    private func trimmedRangeAndSurface(for spanRange: NSRange) -> (range: NSRange, surface: String)? {
        guard spanRange.location != NSNotFound, spanRange.length > 0 else { return nil }
        let storage = inputText as NSString
        guard NSMaxRange(spanRange) <= storage.length else { return nil }
        let local = storage.substring(with: spanRange) as NSString
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
        let highlightRange = NSRange(location: spanRange.location + trimmedLocalRange.location, length: trimmedLocalRange.length)
        let trimmedSurface = local.substring(with: trimmedLocalRange)
        return (highlightRange, trimmedSurface)
    }

    private func aggregatedAnnotatedSpan(for semantic: SemanticSpan) -> AnnotatedSpan {
        let stage1 = furiganaSpans ?? []
        let indices = semantic.sourceSpanIndices
        let group: ArraySlice<AnnotatedSpan>
        if indices.lowerBound >= 0, indices.upperBound <= stage1.count {
            group = stage1[indices.lowerBound..<indices.upperBound]
        } else {
            group = []
        }

        var lemmas: [String] = []
        if group.isEmpty == false {
            var seen: Set<String> = []
            for span in group {
                for lemma in span.lemmaCandidates where seen.contains(lemma) == false {
                    seen.insert(lemma)
                    lemmas.append(lemma)
                }
            }
        }

        let isLexiconMatch = group.contains(where: { $0.span.isLexiconMatch })
        let partOfSpeech = group.compactMap(
            { $0.partOfSpeech }
        ).first
        return AnnotatedSpan(
            span: TextSpan(range: semantic.range, surface: semantic.surface, isLexiconMatch: isLexiconMatch),
            readingKana: semantic.readingKana,
            lemmaCandidates: lemmas,
            partOfSpeech: partOfSpeech
        )
    }

    private func selectionContext(forSpanAt index: Int) -> TokenSelectionContext? {
        guard furiganaSemanticSpans.indices.contains(index) else { return nil }
        let semantic = furiganaSemanticSpans[index]
        guard let trimmed = trimmedRangeAndSurface(for: semantic.range) else { return nil }
        return TokenSelectionContext(
            tokenIndex: index,
            range: trimmed.range,
            surface: trimmed.surface,
            semanticSpan: semantic,
            sourceSpanIndices: semantic.sourceSpanIndices,
            annotatedSpan: aggregatedAnnotatedSpan(for: semantic)
        )
    }

    private func presentDictionaryForSpan(at index: Int, focusSplitMenu: Bool) {
        let contextOpt: TokenSelectionContext? = ivtime("Tap.presentDictionaryForSpan selectionContext") {
            selectionContext(forSpanAt: index)
        }
        guard let context = contextOpt else {
            ivlog("Tap.presentDictionaryForSpan missingContext tokenIndex=\(index)")
            return
        }
        ivlog("Tap.presentDictionaryForSpan haveContext tokenIndex=\(index) range=\(context.range.location)-\(NSMaxRange(context.range)) surfaceLen=\(context.surface.count)")
        pendingSelectionRange = nil
        persistentSelectionRange = context.range
        tokenSelection = context
        // If the Extract Words sheet is open, keep its in-sheet dictionary panel in sync.
        // (The inline dictionary overlay is behind the sheet and not visible.)
        if showTokensPopover {
            sheetSelection = context
        }
        if sheetDictionaryPanelEnabled {
            sheetSelection = context
            // If the Extract Words sheet is open, do not present another sheet (which would
            // dismiss/replace the token list). The token list sheet already renders an
            // in-sheet dictionary panel when `sheetSelection` is set.
            if showTokensPopover == false {
                isDictionarySheetPresented = true
            }
        }
        if dictionaryPopupEnabled {
            let r = context.range
            CustomLogger.shared.debug("Dictionary popup shown tokenIndex=\(index) range=\(r.location)-\(NSMaxRange(r)) surface=\(context.surface) inline=\(self.inlineDictionaryPanelEnabled) sheet=\(self.sheetDictionaryPanelEnabled)")
        }
        pendingSplitFocusSelectionID = focusSplitMenu ? context.id : nil
    }

    private func goToSpanInNote(at index: Int) {
        guard let context = selectionContext(forSpanAt: index) else { return }
        pendingSelectionRange = nil
        persistentSelectionRange = context.range
        tokenSelection = nil
        if sheetDictionaryPanelEnabled {
            sheetSelection = nil
        }
        pendingSplitFocusSelectionID = nil
        showTokensPopover = false
    }

    private func bookmarkToken(at index: Int) {
        guard furiganaSemanticSpans.indices.contains(index) else { return }
        guard let context = selectionContext(forSpanAt: index) else { return }
        let reading = normalizedReading(context.semanticSpan.readingKana)
        let surface = context.surface.trimmingCharacters(in: .whitespacesAndNewlines)

        // Toggle behavior: if already saved, delete; otherwise add
        if hasSavedWord(surface: surface, reading: reading, noteID: currentNote?.id) {
            let matches = words.words.filter { $0.surface == surface && $0.kana == reading && $0.sourceNoteID == currentNote?.id }
            let ids = Set(matches.map { $0.id })
            if ids.isEmpty == false {
                words.delete(ids: ids)
            }
            return
        }

        Task {
            let entry = await lookupPreferredDictionaryEntry(surface: surface, reading: reading)

            await MainActor.run {
                guard let entry else {
                    presentDictionaryForSpan(at: index, focusSplitMenu: false)
                    return
                }
                let meaning = normalizedMeaning(from: entry.gloss)
                guard meaning.isEmpty == false else {
                    presentDictionaryForSpan(at: index, focusSplitMenu: false)
                    return
                }
                let kana = normalizedReading(entry.kana)
                let resolvedSurface = resolvedSurface(from: entry, fallback: context.surface)
                words.add(surface: resolvedSurface, kana: kana, meaning: meaning, note: nil, sourceNoteID: currentNote?.id)
            }
        }
    }

    private func lookupPreferredDictionaryEntry(surface: String, reading: String?) async -> DictionaryEntry? {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = normalizedReading(reading)
        let limit = 8
        if normalizedSurface.isEmpty == false {
            if let entries = try? await DictionarySQLiteStore.shared.lookup(term: normalizedSurface, limit: limit), entries.isEmpty == false {
                if let desired = normalizedReading, let match = entries.first(where: { entryMatchesReading($0, reading: desired) }) {
                    return match
                }
                return entries.first
            }
        }
        if let desired = normalizedReading, desired.isEmpty == false {
            if let readingHits = try? await DictionarySQLiteStore.shared.lookup(term: desired, limit: limit), readingHits.isEmpty == false {
                return readingHits.first
            }
        }
        return nil
    }

    private func entryMatchesReading(_ entry: DictionaryEntry, reading: String) -> Bool {
        guard let kana = normalizedReading(entry.kana) else { return false }
        return kana == reading
    }

    private func normalizedMeaning(from gloss: String) -> String {
        let first = gloss
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? gloss
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedSurface(from entry: DictionaryEntry, fallback: String) -> String {
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the user created/saved a word from a kana surface, preserve that kana surface.
        // Do NOT replace it with the dictionary's kanji spelling.
        if isKanaOnlySurface(trimmedFallback) {
            return trimmedFallback
        }

        let trimmedKanji = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKanji.isEmpty == false {
            return trimmedKanji
        }
        if let kana = normalizedReading(entry.kana) {
            return kana
        }
        return trimmedFallback
    }

    private func isKanaOnlySurface(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            if isKanaScalar(scalar) { return true }
            // Half-width katakana block.
            if (0xFF66...0xFF9F).contains(scalar.value) { return true }
            return false
        }
    }

    private func normalizedReading(_ reading: String?) -> String? {
        guard let value = reading?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else { return nil }
        return value
    }

    private func kanaFoldToHiragana(_ value: String) -> String {
        // Fold katakana/hiragana differences so "カタカナ" and "かたかな" compare equal.
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    private func kanaFoldToHiragana(_ value: String?) -> String? {
        guard let value else { return nil }
        return kanaFoldToHiragana(value)
    }

    private func kanaVariants(_ value: String) -> [String] {
        let hira = kanaFoldToHiragana(value)
        let kata = hira.applyingTransform(.hiraganaToKatakana, reverse: false) ?? hira
        if hira == kata { return [hira] }
        return [hira, kata]
    }

    private func readingWithOkurigana(surface: String, baseReading: String?) -> String? {
        guard var reading = baseReading else { return nil }
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
        scalar.value == 0xFF70
    }

    // Overloaded hasSavedWord with explicit noteID
    private func hasSavedWord(surface: String, reading: String?, noteID: UUID?) -> Bool {
        let targetSurface = kanaFoldToHiragana(surface)
        let targetKana = kanaFoldToHiragana(reading)
        return words.words.contains { word in
            guard word.sourceNoteID == noteID else { return false }
            guard kanaFoldToHiragana(word.surface) == targetSurface else { return false }
            return kanaFoldToHiragana(word.kana) == targetKana
        }
    }

    // Original hasSavedWord calls new overload with currentNote?.id
    private func hasSavedWord(surface: String, reading: String?) -> Bool {
        hasSavedWord(surface: surface, reading: reading, noteID: currentNote?.id)
    }

    private func tokenDuplicateKey(surface: String, reading: String?) -> String {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = reading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(normalizedSurface)|\(normalizedReading)"
    }

    private func mergeSpan(at index: Int, direction: MergeDirection) {
        let wasShowingTokensPopover = showTokensPopover
        guard let pair = stage1MergePair(forSemanticIndex: index, direction: direction) else { return }
        guard let union = applySpanMerge(primaryIndex: pair.primaryIndex, neighborIndex: pair.neighborIndex, actionName: "Merge Tokens") else { return }
        persistentSelectionRange = union
        pendingSelectionRange = union
        let mergedIndex = min(pair.primaryIndex, pair.neighborIndex)
        let textStorage = inputText as NSString
        guard NSMaxRange(union) <= textStorage.length else { return }
        let surface = textStorage.substring(with: union)
        let semantic = SemanticSpan(range: union, surface: surface, sourceSpanIndices: mergedIndex..<(mergedIndex + 1), readingKana: nil)
        let ephemeral = AnnotatedSpan(span: TextSpan(range: union, surface: surface, isLexiconMatch: false), readingKana: nil, lemmaCandidates: [])
        let ctx = TokenSelectionContext(tokenIndex: mergedIndex, range: union, surface: surface, semanticSpan: semantic, sourceSpanIndices: semantic.sourceSpanIndices, annotatedSpan: ephemeral)
        tokenSelection = ctx
        if sheetDictionaryPanelEnabled {
            sheetSelection = ctx
            // If the Extract Words sheet is open, do not present another sheet.
            // The token list sheet renders an in-sheet dictionary panel via `sheetSelection`.
            if wasShowingTokensPopover == false {
                isDictionarySheetPresented = true
            }
        }
        showTokensPopover = wasShowingTokensPopover
    }

    private func startSplitFlow(for index: Int) {
        guard furiganaSemanticSpans.indices.contains(index) else { return }
        let semantic = furiganaSemanticSpans[index]
        guard let trimmed = trimmedRangeAndSurface(for: semantic.range), trimmed.range.length > 1 else { return }
        presentDictionaryForSpan(at: index, focusSplitMenu: true)
    }

    private func canMergeSpan(at index: Int, direction: MergeDirection) -> Bool {
        stage1MergePair(forSemanticIndex: index, direction: direction) != nil
    }

    private func handleOverridesExternalChange() {
        let signature = computeOverrideSignature()
        guard signature != overrideSignature else { return }
        CustomLogger.shared.debug("Override change detected for note=\(activeNoteID)")
        overrideSignature = signature
        updateCustomizedRanges()
        guard inputText.isEmpty == false else { return }
        guard showFurigana || tokenHighlightsEnabled else { return }
        triggerFuriganaRefreshIfNeeded(reason: "reading overrides changed", recomputeSpans: true)
    }

    private func computeOverrideSignature() -> Int {
        let overrides = readingOverrides.overrides(for: activeNoteID).filter { $0.userKana != nil }.sorted { lhs, rhs in
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
        var ranges = readingOverrides.overrides(for: activeNoteID).filter { $0.userKana != nil }.map { $0.nsRange }

        if tokenBoundaries.hasCustomSpans(for: activeNoteID) {
            ranges.append(contentsOf: tokenBoundaries.storedRanges(for: activeNoteID))
        }

        customizedRanges = ranges
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

    private func applyCustomReading(_ kana: String) {
        guard let selection = tokenSelection else { return }
        let trimmed = kana.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let normalized = normalizeOverrideKana(trimmed)
        guard normalized.isEmpty == false else { return }

        let override = ReadingOverride(
            noteID: activeNoteID,
            rangeStart: selection.range.location,
            rangeLength: selection.range.length,
            userKana: normalized
        )
        applyOverridesChange(range: selection.range, newOverrides: [override], actionName: "Apply Custom Reading")
    }

    private func normalizeOverrideKana(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mergeSelection(_ direction: MergeDirection) {
        let wasShowingTokensPopover = showTokensPopover
        guard let selection = tokenSelection else { return }
        guard let pair = stage1MergePair(forSemanticIndex: selection.tokenIndex, direction: direction) else { return }
        guard let union = applySpanMerge(primaryIndex: pair.primaryIndex, neighborIndex: pair.neighborIndex, actionName: "Merge Tokens") else { return }
        persistentSelectionRange = union
        pendingSelectionRange = union
        pendingSplitFocusSelectionID = nil

        let mergedIndex = min(pair.primaryIndex, pair.neighborIndex)
        let textStorage = inputText as NSString
        guard NSMaxRange(union) <= textStorage.length else { return }
        let surface = textStorage.substring(with: union)
        let semantic = SemanticSpan(range: union, surface: surface, sourceSpanIndices: mergedIndex..<(mergedIndex + 1), readingKana: nil)
        let ephemeral = AnnotatedSpan(span: TextSpan(range: union, surface: surface, isLexiconMatch: false), readingKana: nil, lemmaCandidates: [])
        let ctx = TokenSelectionContext(tokenIndex: mergedIndex, range: union, surface: surface, semanticSpan: semantic, sourceSpanIndices: semantic.sourceSpanIndices, annotatedSpan: ephemeral)
        tokenSelection = ctx
        if sheetDictionaryPanelEnabled {
            sheetSelection = ctx
            // If the Extract Words sheet is open, do not present another sheet.
            if wasShowingTokensPopover == false {
                isDictionarySheetPresented = true
            }
        }
        showTokensPopover = wasShowingTokensPopover
    }

    private func splitSelection(at offset: Int) {
        guard let selection = tokenSelection else { return }
        guard selection.range.length > 1 else { return }
        guard offset > 0, offset < selection.range.length else { return }

        let splitUTF16Index = selection.range.location + offset
        guard let stage1 = furiganaSpans else { return }

        let indices = selection.sourceSpanIndices
        let group: ArraySlice<AnnotatedSpan>
        if indices.lowerBound >= 0, indices.upperBound <= stage1.count {
            group = stage1[indices.lowerBound..<indices.upperBound]
        } else {
            group = []
        }

        let stage1Index: Int? = {
            if let local = group.enumerated().first(where: { NSLocationInRange(splitUTF16Index, $0.element.span.range) })?.offset {
                return indices.lowerBound + local
            }
            return stage1.enumerated().first(where: { NSLocationInRange(splitUTF16Index, $0.element.span.range) })?.offset
        }()

        // If the requested split falls exactly on an existing Stage-1 boundary, we can't split
        // inside a span. Instead, record an explicit non-crossable cut so Stage-2.5 won't merge
        // across it.
        if stage1Index == nil {
            // (Should be rare because the search above typically finds a containing span.)
            tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: splitUTF16Index, text: inputText)
            triggerFuriganaRefreshIfNeeded(reason: "Split Token", recomputeSpans: true)
            clearSelection(resetPersistent: false)
            return
        }

        guard let spanIndex = stage1Index, stage1.indices.contains(spanIndex) else { return }
        let spanRange = stage1[spanIndex].span.range
        let localOffset = splitUTF16Index - spanRange.location

        if localOffset <= 0 || localOffset >= spanRange.length {
            tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: splitUTF16Index, text: inputText)
            triggerFuriganaRefreshIfNeeded(reason: "Split Token", recomputeSpans: true)
            clearSelection(resetPersistent: false)
            return
        }

        applySpanSplit(spanIndex: spanIndex, range: spanRange, offset: localOffset, actionName: "Split Token")
        clearSelection(resetPersistent: false)
    }

    private func resetSelectionOverrides() {
        guard let selection = tokenSelection else { return }
        applyOverridesChange(range: selection.range, newOverrides: [], actionName: "Reset Token")
        resetSpanEdits(in: selection.range, actionName: "Reset Token")
        clearSelection(resetPersistent: false)
    }

    private func resetAllCustomSpans() {
        let noteID = activeNoteID
        let previousAllOverrides = readingOverrides.allOverrides()
        let previousSpanSnapshot = tokenBoundaries.snapshot(for: noteID)

        readingOverrides.removeAll(for: noteID)
        tokenBoundaries.removeAll(for: noteID)
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        clearSelection()
        triggerFuriganaRefreshIfNeeded(reason: "reset all overrides", recomputeSpans: true)

        registerResetAllUndo(previousAllOverrides: previousAllOverrides, previousSpanSnapshot: previousSpanSnapshot, noteID: noteID)
    }

    private func applySpanMerge(primaryIndex: Int, neighborIndex: Int, actionName: String) -> NSRange? {
        guard let spans = furiganaSpans else { return nil }
        let indices = [primaryIndex, neighborIndex].sorted()
        guard spans.indices.contains(indices[0]), spans.indices.contains(indices[1]) else { return nil }

        let union = NSUnionRange(spans[indices[0]].span.range, spans[indices[1]].span.range)
        let nsText = inputText as NSString
        guard union.location != NSNotFound, union.length > 0 else { return nil }
        guard NSMaxRange(union) <= nsText.length else { return nil }
        let mergedSurface = nsText.substring(with: union)

        var newSpans = spans.map(\.span)
        newSpans.remove(at: indices[1])
        newSpans.remove(at: indices[0])
        newSpans.insert(TextSpan(range: union, surface: mergedSurface, isLexiconMatch: false), at: indices[0])

        replaceSpans(newSpans, actionName: actionName)
        return union
    }

    private func applySpanSplit(spanIndex: Int, range: NSRange, offset: Int, actionName: String) {
        guard let spans = furiganaSpans else { return }
        guard spans.indices.contains(spanIndex) else { return }
        guard range.length > 1 else { return }
        guard offset > 0, offset < range.length else { return }

        let leftRange = NSRange(location: range.location, length: offset)
        let rightRange = NSRange(location: range.location + offset, length: range.length - offset)
        let nsText = inputText as NSString
        guard NSMaxRange(rightRange) <= nsText.length else { return }

        let leftSurface = nsText.substring(with: leftRange)
        let rightSurface = nsText.substring(with: rightRange)

        var newSpans = spans.map(\.span)
        newSpans.remove(at: spanIndex)
        newSpans.insert(TextSpan(range: rightRange, surface: rightSurface, isLexiconMatch: false), at: spanIndex)
        newSpans.insert(TextSpan(range: leftRange, surface: leftSurface, isLexiconMatch: false), at: spanIndex)
        replaceSpans(newSpans, actionName: actionName)
    }

    private func resetSpanEdits(in range: NSRange, actionName: String) {
        guard inputText.isEmpty == false else { return }
        let noteID = activeNoteID
        guard tokenBoundaries.hasCustomSpans(for: noteID) else { return }
        let text = inputText
        let previousSnapshot = tokenBoundaries.snapshot(for: noteID)
        registerSpanUndo(previousSnapshot: previousSnapshot, noteID: noteID, actionName: actionName)

        Task {
            do {
                let base = try await SegmentationService.shared.segment(text: text)
                let replacement = base.filter { NSIntersectionRange($0.range, range).length > 0 }
                await MainActor.run {
                    replaceSpans(in: range, with: replacement, actionName: actionName)
                }
            } catch {
                return
            }
        }
    }

    private func replaceSpans(_ spans: [TextSpan], actionName: String) {
        let noteID = activeNoteID
        let previousSnapshot = tokenBoundaries.snapshot(for: noteID)
        registerSpanUndo(previousSnapshot: previousSnapshot, noteID: noteID, actionName: actionName)
        tokenBoundaries.setSpans(noteID: noteID, spans: spans, text: inputText)
        updateCustomizedRanges()
        triggerFuriganaRefreshIfNeeded(reason: actionName, recomputeSpans: true)
    }

    private func replaceSpans(in range: NSRange, with replacement: [TextSpan], actionName: String) {
        let noteID = activeNoteID
        let text = inputText
        var base = tokenBoundaries.spans(for: noteID, text: text) ?? furiganaSpans?.map(\.span) ?? []
        base.removeAll { NSIntersectionRange($0.range, range).length > 0 }
        base.append(contentsOf: replacement)
        base.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location { return lhs.range.length < rhs.range.length }
            return lhs.range.location < rhs.range.location
        }
        tokenBoundaries.setSpans(noteID: noteID, spans: base, text: text)
        updateCustomizedRanges()
        triggerFuriganaRefreshIfNeeded(reason: actionName, recomputeSpans: true)
    }

    private func registerSpanUndo(previousSnapshot: [TokenBoundariesStore.StoredSpan]?, noteID: UUID, actionName: String) {
        guard let undoManager else { return }
        let token = OverrideUndoToken { [self] in
            tokenBoundaries.restore(noteID: noteID, snapshot: previousSnapshot)
            updateCustomizedRanges()
            triggerFuriganaRefreshIfNeeded(reason: "undo: \(actionName)", recomputeSpans: true)
        }
        undoManager.registerUndo(withTarget: token) { target in
            target.perform()
        }
        undoManager.setActionName(actionName)
    }

    private func registerResetAllUndo(previousAllOverrides: [ReadingOverride], previousSpanSnapshot: [TokenBoundariesStore.StoredSpan]?, noteID: UUID) {
        guard let undoManager else { return }
        let token = OverrideUndoToken { [self] in
            readingOverrides.replaceAll(with: previousAllOverrides)
            tokenBoundaries.restore(noteID: noteID, snapshot: previousSpanSnapshot)
            overrideSignature = computeOverrideSignature()
            updateCustomizedRanges()
            triggerFuriganaRefreshIfNeeded(reason: "undo: reset all", recomputeSpans: true)
        }
        undoManager.registerUndo(withTarget: token) { target in
            target.perform()
        }
        undoManager.setActionName("Reset All")
    }

    private func processPendingRouterResetRequest() {
        guard let requestedID = pendingRouterResetNoteID else { return }
        guard let activeID = currentNote?.id, requestedID == activeID else { return }
        pendingRouterResetNoteID = nil
        router.pendingResetNoteID = nil
        resetAllCustomSpans()
    }

    private func applyOverridesChange(range: NSRange, newOverrides: [ReadingOverride], actionName: String) {
        let noteID = activeNoteID
        let previous = readingOverrides.overrides(for: noteID, overlapping: range)
        CustomLogger.shared.debug("Applying overrides action=\(actionName) note=\(noteID) range=\(range.location)-\(NSMaxRange(range)) replacing=\(previous.count) inserting=\(newOverrides.count)")
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
        return stage1MergePair(forSemanticIndex: selection.tokenIndex, direction: direction) != nil
    }

    private func stage1MergePair(forSemanticIndex index: Int, direction: MergeDirection) -> (primaryIndex: Int, neighborIndex: Int)? {
        guard let stage1 = furiganaSpans else { return nil }
        guard furiganaSemanticSpans.indices.contains(index) else { return nil }
        let semantic = furiganaSemanticSpans[index]
        let lower = semantic.sourceSpanIndices.lowerBound
        let upper = semantic.sourceSpanIndices.upperBound
        guard lower >= 0, upper <= stage1.count else { return nil }

        switch direction {
        case .previous:
            let neighbor = lower - 1
            let primary = lower
            guard stage1.indices.contains(neighbor), stage1.indices.contains(primary) else { return nil }
            return (primaryIndex: primary, neighborIndex: neighbor)
        case .next:
            let neighbor = upper
            let primary = upper - 1
            guard stage1.indices.contains(neighbor), stage1.indices.contains(primary) else { return nil }
            return (primaryIndex: primary, neighborIndex: neighbor)
        }
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

    private func setEditing(_ editing: Bool) {
        isEditing = editing
    }

    private func ensureInitialFuriganaReady(reason: String) {
        if skipNextInitialFuriganaEnsure {
            return
        }
        guard furiganaSpans == nil || furiganaAttributedText == nil else { return }
        guard inputText.isEmpty == false else { return }
        triggerFuriganaRefreshIfNeeded(reason: reason, recomputeSpans: true)
    }

    private func triggerFuriganaRefreshIfNeeded(reason: String = "state change", recomputeSpans: Bool = true) {
        guard inputText.isEmpty == false else {
            CustomLogger.shared.info("Skipping refresh (\(reason)): paste text is empty.")
            return
        }
        furiganaRefreshToken &+= 1
        CustomLogger.shared.info("Queued refresh token \(furiganaRefreshToken) for text length \(inputText.count). Reason: \(reason)")
        startFuriganaTask(token: furiganaRefreshToken, recomputeSpans: recomputeSpans)
    }

    private func assignInputTextFromExternalSource(_ text: String) {
        guard inputText != text else { return }
        skipNextInitialFuriganaEnsure = true
        inputText = text
    }

    private func startFuriganaTask(token: Int, recomputeSpans: Bool) {
        guard let taskBody = makeFuriganaTask(token: token, recomputeSpans: recomputeSpans) else { return }
        furiganaTaskHandle?.cancel()
        furiganaTaskHandle = Task {
            await taskBody()
        }
    }

    private func makeFuriganaTask(token: Int, recomputeSpans: Bool) -> (() async -> Void)? {
        guard inputText.isEmpty == false else {
            CustomLogger.shared.info("No furigana task created because text is empty.")
            return nil
        }

        // INVESTIGATION NOTES (2026-01-04)
        // Initial load / furigana recompute execution path:
        // PasteView.triggerFuriganaRefreshIfNeeded → startFuriganaTask → makeFuriganaTask → FuriganaPipelineService.render.
        // FuriganaPipelineService.render → FuriganaAttributedTextBuilder.computeStage2 → Stage-1 segmentation → Stage-2 attachReadings
        // (now includes Stage-2.5 semanticRegrouping) → ruby projection (when showFurigana == true).
        //
        // Main-thread boundary:
        // `service.render(...)` runs off-main; applying results is wrapped in `MainActor.run`.
        // Any heavy work inside rendering/ruby layout that happens on the main thread should be flagged separately (see RubyText).
        // Capture current values by value to avoid capturing self
        let currentText = inputText
        let currentShowFurigana = showFurigana
        let currentSpanConsumersActive = spanConsumersActive
        let currentTextSize = readingTextSize
        let currentFuriganaSize = readingFuriganaSize
        let currentSpans = furiganaSpans
        let currentSemanticSpans = furiganaSemanticSpans
        let currentOverrides = readingOverrides.overrides(for: activeNoteID).filter { $0.userKana != nil }
        let currentAmendedSpans = tokenBoundaries.spans(for: activeNoteID, text: currentText)
        let currentHardCuts = tokenBoundaries.hardCuts(for: activeNoteID, text: currentText)
        let pipelineInput = FuriganaPipelineService.Input(
            text: currentText,
            showFurigana: currentShowFurigana,
            needsTokenHighlights: currentSpanConsumersActive,
            textSize: currentTextSize,
            furiganaSize: currentFuriganaSize,
            recomputeSpans: recomputeSpans,
            existingSpans: currentSpans,
            existingSemanticSpans: currentSemanticSpans,
            amendedSpans: currentAmendedSpans,
            hardCuts: currentHardCuts,
            readingOverrides: currentOverrides,
            context: "PasteView"
        )
        let service = furiganaPipeline
        CustomLogger.shared.info("Creating furigana task token \(token) for text length \(currentText.count). ShowFurigana: \(currentShowFurigana)")
        return {
            let result = await service.render(pipelineInput)
            await MainActor.run {
                guard Task.isCancelled == false else {
                    CustomLogger.shared.info("Discarded cancelled furigana task token \(token)")
                    return
                }
                guard token == furiganaRefreshToken else {
                    CustomLogger.shared.info("Discarded stale furigana result token \(token); latest token is \(furiganaRefreshToken)")
                    return
                }
                guard inputText == currentText else {
                    CustomLogger.shared.info("Discarded furigana result token \(token) because text changed before apply")
                    return
                }
                furiganaSpans = result.spans
                furiganaSemanticSpans = result.semanticSpans
                CustomLogger.shared.info("Applied spans: \(result.spans?.count ?? 0)")
                if showFurigana == currentShowFurigana {
                    furiganaAttributedText = result.attributedString
                } else if showFurigana == false {
                    furiganaAttributedText = nil
                }
                restoreSelectionIfNeeded()
            }
        }
    }

    @MainActor
    private func restoreSelectionIfNeeded() {
        guard let targetRange = pendingSelectionRange else { return }
        let spans = furiganaSemanticSpans
        guard spans.isEmpty == false else { return }
        guard let match = spans.enumerated().first(where: { $0.element.range == targetRange }) else { return }
        let textStorage = inputText as NSString
        guard NSMaxRange(targetRange) <= textStorage.length else {
            pendingSelectionRange = nil
            return
        }
        let surface = textStorage.substring(with: targetRange)
        let semantic = match.element
        let context = TokenSelectionContext(
            tokenIndex: match.offset,
            range: targetRange,
            surface: surface,
            semanticSpan: semantic,
            sourceSpanIndices: semantic.sourceSpanIndices,
            annotatedSpan: aggregatedAnnotatedSpan(for: semantic)
        )
        tokenSelection = context
        if sheetDictionaryPanelEnabled {
            sheetSelection = context
        }
        pendingSelectionRange = nil
    }

    private func saveAllVisibleTokens() {
        let noteID = currentNote?.id
        let items = tokenListItems
        guard items.isEmpty == false else { return }

        Task {
            let existingKeys: Set<String> = await MainActor.run {
                Set(
                    words.words
                        .filter { $0.sourceNoteID == noteID }
                        .map { w in
                            let s = w.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                            let k = w.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let nk = (k?.isEmpty == false) ? k! : ""
                            return "\(s)|\(nk)"
                        }
                )
            }

            var toAdd: [WordsStore.WordToAdd] = []
            toAdd.reserveCapacity(items.count)

            for item in items {
                // Skip if already saved for this note
                let candidateKey: String = {
                    let s = item.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                    let k = item.reading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return "\(s)|\(k)"
                }()
                if existingKeys.contains(candidateKey) {
                    continue
                }
                // Lookup preferred dictionary entry for richer meaning/surface if available
                let entry = await lookupPreferredDictionaryEntry(surface: item.surface, reading: item.reading)

                guard let entry else { continue }
                let meaning = normalizedMeaning(from: entry.gloss)
                guard meaning.isEmpty == false else { continue }
                let kana = normalizedReading(entry.kana)
                let surface = resolvedSurface(from: entry, fallback: item.surface)
                toAdd.append(WordsStore.WordToAdd(surface: surface, kana: kana, meaning: meaning))
            }

            await MainActor.run {
                words.addMany(toAdd, sourceNoteID: noteID)
            }
        }
    }

}

private enum MergeDirection {
    case previous
    case next
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

// MARK: - Incremental Lookup (PasteView)

private struct IncrementalLookupHit: Identifiable, Hashable {
    let matchedSurface: String
    let entry: DictionaryEntry

    var id: String { "\(matchedSurface)#\(entry.id)" }
}

private struct IncrementalLookupCollapsed: Identifiable, Hashable {
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

private struct IncrementalLookupGroup: Identifiable, Hashable {
    let matchedSurface: String
    let pages: [IncrementalLookupCollapsed]

    var id: String { matchedSurface }
}

extension PasteView {
    private var incrementalPopupGroups: [IncrementalLookupGroup] {
        guard incrementalPopupHits.isEmpty == false else { return [] }

        // Preserve first-seen order per surface.
        struct Bucket {
            var firstIndex: Int
            var surface: String
            var hits: [IncrementalLookupHit]
        }

        var buckets: [String: Bucket] = [:]
        buckets.reserveCapacity(min(32, incrementalPopupHits.count))

        for (idx, hit) in incrementalPopupHits.enumerated() {
            let foldedKey = kanaFoldToHiragana(hit.matchedSurface.trimmingCharacters(in: .whitespacesAndNewlines))
            if var existing = buckets[foldedKey] {
                existing.hits.append(hit)
                buckets[foldedKey] = existing
            } else {
                buckets[foldedKey] = Bucket(firstIndex: idx, surface: hit.matchedSurface, hits: [hit])
            }
        }

        let ordered = buckets.values.sorted { $0.firstIndex < $1.firstIndex }

        func normalizeKanji(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func normalizeGloss(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ordered.map { bucket in
            // Collapse entries that share (kanji, gloss) by combining their kana variants.
            var collapsedByKey: [String: (kanji: String, gloss: String, kana: [String], entries: [DictionaryEntry], firstIndex: Int)] = [:]
            collapsedByKey.reserveCapacity(min(16, bucket.hits.count))

            for (localIndex, hit) in bucket.hits.enumerated() {
                let kanji = normalizeKanji(hit.entry.kanji)
                let gloss = normalizeGloss(hit.entry.gloss)
                let key = "\(kanji)#\(gloss)"
                let kana = normalizedReading(hit.entry.kana)

                if var existing = collapsedByKey[key] {
                    if let kana, existing.kana.contains(kana) == false {
                        existing.kana.append(kana)
                    }
                    existing.entries.append(hit.entry)
                    collapsedByKey[key] = existing
                } else {
                    collapsedByKey[key] = (
                        kanji: kanji,
                        gloss: gloss,
                        kana: kana.map { [$0] } ?? [],
                        entries: [hit.entry],
                        firstIndex: localIndex
                    )
                }
            }

            let pages: [IncrementalLookupCollapsed] = collapsedByKey.values
                .sorted { $0.firstIndex < $1.firstIndex }
                .map { item in
                    let kanaList: String?
                    if item.kana.isEmpty {
                        kanaList = nil
                    } else {
                        kanaList = item.kana.joined(separator: "; ")
                    }
                    return IncrementalLookupCollapsed(
                        matchedSurface: bucket.surface,
                        kanji: item.kanji,
                        gloss: item.gloss,
                        kanaList: kanaList,
                        entries: item.entries
                    )
                }

            return IncrementalLookupGroup(matchedSurface: bucket.surface, pages: pages)
        }
    }

    @ViewBuilder
    fileprivate var incrementalLookupSheet: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(incrementalPopupGroups) { group in
                    if group.pages.count <= 1, let page = group.pages.first {
                        incrementalPopupPage(page)
                    } else {
                        TabView {
                            ForEach(group.pages) { page in
                                incrementalPopupPage(page)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(height: 110)
                    }

                    Divider()
                }
            }
            .padding(14)
        }
        .background(Color(UIColor.systemBackground))
        .onAppear {
            incrementalSheetDetent = incrementalPreferredSheetDetent
        }
        .onChange(of: incrementalPopupHits) { _, _ in
            incrementalSheetDetent = incrementalPreferredSheetDetent
        }
    }

    private func incrementalPopupPage(_ page: IncrementalLookupCollapsed) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.matchedSurface)
                    .font(.headline)
                    .lineLimit(1)

                Text(page.gloss)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                if let kanaList = page.kanaList, kanaList.isEmpty == false {
                    Text(kanaList)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let isAnySaved = page.entries.contains { isSavedWord(for: page.matchedSurface, entry: $0) }
            Button {
                if isAnySaved {
                    for entry in page.entries where isSavedWord(for: page.matchedSurface, entry: entry) {
                        toggleSavedWord(surface: page.matchedSurface, entry: entry)
                    }
                } else if let first = page.entries.first {
                    toggleSavedWord(surface: page.matchedSurface, entry: first)
                }
                recomputeSavedWordOverlays()
            } label: {
                Image(systemName: isAnySaved ? "bookmark.fill" : "bookmark")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isAnySaved ? "Remove Bookmark" : "Bookmark")
        }
        .padding(.vertical, 10)
    }

    fileprivate func startIncrementalLookup(atUTF16Index index: Int) {
        guard incrementalLookupEnabled else { return }
        let nsText = inputText as NSString
        guard nsText.length > 0 else { return }
        guard index >= 0, index < nsText.length else { return }

        // If the tap lands on a newline, ignore.
        let tappedRange = nsText.rangeOfComposedCharacterSequence(at: index)
        let tappedChar = nsText.substring(with: tappedRange)
        if tappedChar == "\n" || tappedChar == "\r" {
            incrementalLookupTask?.cancel()
            incrementalSelectedCharacterRange = nil
            isIncrementalPopupVisible = false
            incrementalPopupHits = []
            return
        }

        incrementalLookupTask?.cancel()
        incrementalPopupHits = []
        isIncrementalPopupVisible = false

        let start = tappedRange.location
        incrementalLookupTask = Task {
            let candidates = buildIncrementalCandidates(from: start, nsText: nsText)
            var hits: [IncrementalLookupHit] = []
            hits.reserveCapacity(16)
            var seen: Set<String> = []

            // If Stage-2 semantic spans are ready, we can reuse their MeCab-derived lemma candidates.
            // This lets inflected surfaces still count as "a word" (lookup via lemma) without running
            // MeCab again per incremental candidate.
            let lemmaCandidatesBySurface: [String: [String]] = await MainActor.run {
                var out: [String: [String]] = [:]
                for semantic in furiganaSemanticSpans {
                    // Only consider spans that begin at the tapped offset.
                    guard semantic.range.location == start else { continue }
                    let surface = semantic.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard surface.isEmpty == false else { continue }
                    let lemmas = aggregatedAnnotatedSpan(for: semantic)
                        .lemmaCandidates
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.isEmpty == false }
                    if lemmas.isEmpty == false {
                        out[surface] = lemmas
                    }
                }
                return out
            }

            func appendRows(_ rows: [DictionaryEntry], matchedSurface: String) async {
                // This Task is not main-actor isolated; only touch MainActor-isolated properties via MainActor.run.
                let folded = matchedSurface.applyingTransform(.hiraganaToKatakana, reverse: true) ?? matchedSurface
                for row in rows {
                    let rowID = await MainActor.run { row.id }
                    let key = "\(folded)#\(rowID)"
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    hits.append(IncrementalLookupHit(matchedSurface: matchedSurface, entry: row))
                }
            }

            for cand in candidates {
                guard Task.isCancelled == false else { return }
                let trimmed = cand.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { continue }

                if let rows = try? await DictionarySQLiteStore.shared.lookup(term: trimmed, limit: 50), rows.isEmpty == false {
                    await appendRows(rows, matchedSurface: trimmed)
                    continue
                }

                // Lemmatization fallback: if this candidate corresponds to a Stage-2 token surface,
                // try its lemma candidates (base forms) against the dictionary.
                if let lemmas = lemmaCandidatesBySurface[trimmed], lemmas.isEmpty == false {
                    for lemma in lemmas {
                        guard Task.isCancelled == false else { return }
                        if let rows = try? await DictionarySQLiteStore.shared.lookup(term: lemma, limit: 50), rows.isEmpty == false {
                            await appendRows(rows, matchedSurface: trimmed)
                        }
                    }
                }
            }

            guard Task.isCancelled == false else { return }
            await MainActor.run {
                incrementalPopupHits = hits
                isIncrementalPopupVisible = hits.isEmpty == false
                if hits.isEmpty == false {
                    incrementalSheetDetent = incrementalPreferredSheetDetent
                }
            }
        }
    }

    private func buildIncrementalCandidates(from start: Int, nsText: NSString) -> [String] {
        guard start >= 0, start < nsText.length else { return [] }
        var out: [String] = []
        out.reserveCapacity(24)

        var cursor = start
        // First character already confirmed non-newline.
        let first = nsText.rangeOfComposedCharacterSequence(at: cursor)
        cursor = NSMaxRange(first)
        out.append(nsText.substring(with: NSRange(location: start, length: cursor - start)))

        while cursor < nsText.length {
            let next = nsText.rangeOfComposedCharacterSequence(at: cursor)
            let ch = nsText.substring(with: next)
            if ch == "\n" || ch == "\r" { break }
            cursor = NSMaxRange(next)
            out.append(nsText.substring(with: NSRange(location: start, length: cursor - start)))
        }

        return out
    }

    fileprivate func recomputeSavedWordOverlays() {
        guard incrementalLookupEnabled else {
            savedWordOverlays = []
            return
        }
        guard let noteID = currentNote?.id else {
            savedWordOverlays = []
            return
        }
        let savedWords = words.words
            .filter { $0.sourceNoteID == noteID }
        let candidateSurfaces = savedWords
            .map { $0.surface.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard candidateSurfaces.isEmpty == false else {
            savedWordOverlays = []
            return
        }
        let nsText = inputText as NSString
        guard nsText.length > 0 else {
            savedWordOverlays = []
            return
        }

        let savedColor = UIColor(hexString: alternateTokenColorAHex) ?? UIColor.systemBlue

        var overlays: [RubyText.TokenOverlay] = []
        overlays.reserveCapacity(min(256, candidateSurfaces.count * 2))

        var seenRanges: Set<String> = []

        // Primary path: use Stage-2 spans (surface + lemma candidates) so bookmarked base forms
        // will still color inflected occurrences in running text.
        let savedSurfaceKeys = Set(candidateSurfaces.map { kanaFoldToHiragana($0) })
        if furiganaSemanticSpans.isEmpty == false {
            for semantic in furiganaSemanticSpans {
                guard semantic.range.location != NSNotFound, semantic.range.length > 0 else { continue }
                guard NSMaxRange(semantic.range) <= nsText.length else { continue }

                let surface = semantic.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }

                let aggregated = aggregatedAnnotatedSpan(for: semantic)
                var candidates: [String] = []
                candidates.reserveCapacity(1 + aggregated.lemmaCandidates.count)
                candidates.append(surface)
                candidates.append(contentsOf: aggregated.lemmaCandidates)

                var isSaved = false
                for cand in candidates {
                    let trimmed = cand.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { continue }
                    if savedSurfaceKeys.contains(kanaFoldToHiragana(trimmed)) {
                        isSaved = true
                        break
                    }
                }
                guard isSaved else { continue }

                let rangeKey = "\(semantic.range.location)#\(semantic.range.length)"
                if seenRanges.contains(rangeKey) == false {
                    seenRanges.insert(rangeKey)
                    overlays.append(RubyText.TokenOverlay(range: semantic.range, color: savedColor))
                }
            }
        }

        // Fallback path: literal substring scan for cases where spans aren't available yet.
        for surface in candidateSurfaces {
            for variant in kanaVariants(surface) {
                var search = NSRange(location: 0, length: nsText.length)
                while search.length > 0 {
                    let found = nsText.range(of: variant, options: [], range: search)
                    if found.location == NSNotFound || found.length == 0 { break }
                    let rangeKey = "\(found.location)#\(found.length)"
                    if seenRanges.contains(rangeKey) == false {
                        seenRanges.insert(rangeKey)
                        overlays.append(RubyText.TokenOverlay(range: found, color: savedColor))
                    }
                    let nextLoc = NSMaxRange(found)
                    if nextLoc >= nsText.length { break }
                    search = NSRange(location: nextLoc, length: nsText.length - nextLoc)
                }
            }
        }

        savedWordOverlays = overlays
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

