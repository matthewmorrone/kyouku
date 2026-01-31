import SwiftUI
import UIKit
import Foundation

struct PasteView: View {
    // NOTE: The semantic heatmap/constellation is intentionally disabled for now.
    // Leave the code in place so we can revisit it later.
    private static let sentenceHeatmapEnabledFlag: Bool = false

    @EnvironmentObject var notes: NotesStore
    private struct TokenActionPanelFramePreferenceKey: PreferenceKey {
        static var defaultValue: CGRect? = nil

        static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
            if let next = nextValue() {
                value = next
            }
        }
    }
    private struct PasteAreaFramePreferenceKey: PreferenceKey {
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
    @Environment(\.appColorTheme) private var appColorTheme

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var noteTitleInput: String = ""
    @State private var hasManuallyEditedTitle: Bool = false
    @State private var isTitleEditAlertPresented: Bool = false
    @State private var titleEditDraft: String = ""
    @State private var hasInitialized: Bool = false
    @State private var isEditing: Bool = false
    @State private var furiganaAttributedText: NSAttributedString? = nil
    @State private var furiganaAttributedTextBase: NSAttributedString? = nil
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
    @State private var debugTokenListText: String = ""
    @State private var pendingRouterResetNoteID: UUID? = nil
    @State private var skipNextInitialFuriganaEnsure: Bool = false
    @State private var isDictionarySheetPresented: Bool = false
    @State private var measuredSheetHeight: CGFloat = 0
    @State private var pasteAreaFrame: CGRect? = nil

    @State private var toastText: String? = nil
    @State private var toastDismissWorkItem: DispatchWorkItem? = nil

    // Incremental lookup (tap character → lookup n, n+n1, ..., up to next newline)
    @State private var incrementalPopupHits: [IncrementalLookupHit] = []
    @State private var isIncrementalPopupVisible: Bool = false
    @State private var incrementalLookupTask: Task<Void, Never>? = nil
    @State private var savedWordOverlays: [RubyText.TokenOverlay] = []
    @State private var incrementalSelectedCharacterRange: NSRange? = nil
    @State private var incrementalSheetDetent: PresentationDetent = .height(420)

    // Sentence-level semantic heatmap (visual-only)
    @State private var sentenceRanges: [NSRange] = []
    @State private var sentenceVectors: [[Float]?] = []
    @State private var sentenceHeatmapSelectedIndex: Int? = nil
    @State private var sentenceHeatmapTask: Task<Void, Never>? = nil

    // Live semantic feedback while editing (read-only)
    @State private var editorSelectedRange: NSRange? = nil
    @State private var liveSemanticFeedback: LiveSemanticFeedback? = nil
    @State private var liveSemanticFeedbackTask: Task<Void, Never>? = nil

    // Semantic constellation (sentence graph)
    @State private var isConstellationSheetPresented: Bool = false
    @State private var constellationScrollToSelectedRangeToken: Int = 0

    @State private var showWordDefinitionsSheet: Bool = false
    @State private var wordDefinitionsSurface: String = ""
    @State private var wordDefinitionsKana: String? = nil
    @State private var wordDefinitionsContextSentence: String? = nil
    @State private var wordDefinitionsLemmaCandidates: [String] = []
    @State private var wordDefinitionsPartOfSpeech: String? = nil
    @State private var wordDefinitionsTokenParts: [WordDefinitionsView.TokenPart] = []

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
    @AppStorage("readingGlobalKerningPixels") private var readingGlobalKerningPixels: Double = 0
    @AppStorage("readingHeadwordSpacingPadding") private var readingHeadwordSpacingPadding: Bool = false
    @AppStorage("readingShowFurigana") private var showFurigana: Bool = true
    @AppStorage("readingWrapLines") private var wrapLines: Bool = false
    @AppStorage("readingAlternateTokenColors") private var alternateTokenColors: Bool = false
    @AppStorage("readingHighlightUnknownTokens") private var highlightUnknownTokens: Bool = false
    // One-time migration to disable token overlay highlighting that can hurt responsiveness.
    // Users can re-enable manually in the furigana options menu if desired.
    @AppStorage("paste.migrated.disableTokenOverlayHighlighting.v1") private var didDisableTokenOverlayHighlightingV1: Bool = false
    @AppStorage("readingAlternateTokenColorA") private var alternateTokenColorAHex: String = "#0A84FF"
    @AppStorage("readingAlternateTokenColorB") private var alternateTokenColorBHex: String = "#FF2D55"
    @AppStorage(FuriganaKnownWordSettings.modeKey) private var knownWordFuriganaModeRaw: String = FuriganaKnownWordSettings.defaultModeRawValue
    @AppStorage(FuriganaKnownWordSettings.scoreThresholdKey) private var knownWordFuriganaScoreThreshold: Double = FuriganaKnownWordSettings.defaultScoreThreshold
    @AppStorage(FuriganaKnownWordSettings.minimumReviewsKey) private var knownWordFuriganaMinimumReviews: Int = FuriganaKnownWordSettings.defaultMinimumReviews

    @State private var showingFuriganaOptions: Bool = false
    @AppStorage("pasteViewScratchNoteID") private var scratchNoteIDRaw: String = ""
    @AppStorage("pasteViewLastOpenedNoteID") private var lastOpenedNoteIDRaw: String = ""
    @AppStorage("extractHideDuplicateTokens") private var hideDuplicateTokens: Bool = false
    @AppStorage("extractHideCommonParticles") private var hideCommonParticles: Bool = false
    @AppStorage("extractPropagateTokenEdits") private var propagateTokenEdits: Bool = false
    @AppStorage(CommonParticleSettings.storageKey) private var commonParticlesRaw: String = CommonParticleSettings.defaultRawValue
    @AppStorage("debugDisableDictionaryPopup") private var debugDisableDictionaryPopup: Bool = false
    @AppStorage("debugTokenGeometryOverlay") private var debugTokenGeometryOverlay: Bool = false

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
    private static let dictionaryPopupLoggingEnabledFlag = false
    private static let incrementalLookupEnabledFlag = false
    private static let sheetMaxHeightFraction: CGFloat = 0.8
    private static let sheetExtraPadding: CGFloat = 36
    private let furiganaPipeline = FuriganaPipelineService()
    private var incrementalLookupEnabled: Bool { Self.incrementalLookupEnabledFlag }
    private var dictionaryPopupEnabled: Bool { Self.dictionaryPopupEnabledFlag && incrementalLookupEnabled == false && debugDisableDictionaryPopup == false }
    private var dictionaryPopupLoggingEnabled: Bool { Self.dictionaryPopupLoggingEnabledFlag }
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
        // Honor user overrides when provided; otherwise prefer theme defaults.
        let defaultA = UIColor(appColorTheme.palette.tokenAlternateA)
        let defaultB = UIColor(appColorTheme.palette.tokenAlternateB)

        let chosenA = UIColor(hexString: alternateTokenColorAHex) ?? defaultA
        let chosenB = UIColor(hexString: alternateTokenColorBHex) ?? defaultB
        return [chosenA, chosenB]
    }
    private var unknownTokenColor: UIColor { UIColor(appColorTheme.palette.unknownToken) }
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

    private func sanitizeGeometryRect(_ rect: CGRect?) -> CGRect? {
        guard var rect = rect else { return nil }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return nil }
        guard rect.size.width.isFinite, rect.size.height.isFinite else { return nil }
        rect.size.width = max(0, rect.size.width)
        rect.size.height = max(0, rect.size.height)
        return rect
    }

    private func sanitizeLength(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    var body: some View {
        NavigationStack {
            applyDictionarySheet(to: coreContent)
        }
        .onPreferenceChange(TokenActionPanelFramePreferenceKey.self) { newValue in
            tokenPanelFrame = sanitizeGeometryRect(newValue)
        }
        .onPreferenceChange(PasteAreaFramePreferenceKey.self) { newValue in
            pasteAreaFrame = sanitizeGeometryRect(newValue)
        }
        .sheet(isPresented: $showWordDefinitionsSheet, onDismiss: {
            // When the dictionary details sheet is dismissed, also clear the
            // token selection in the paste area so the highlight goes away.
            clearSelection(resetPersistent: true)
        }) {
            NavigationStack {
                WordDefinitionsView(
                    surface: wordDefinitionsSurface,
                    kana: wordDefinitionsKana,
                    contextSentence: wordDefinitionsContextSentence,
                    lemmaCandidates: wordDefinitionsLemmaCandidates,
                    tokenPartOfSpeech: wordDefinitionsPartOfSpeech,
                    sourceNoteID: currentNote?.id,
                    tokenParts: wordDefinitionsTokenParts
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
            .overlay {
                if isTitleEditAlertPresented {
                    titleEditModal
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.9), value: isTitleEditAlertPresented)
            .safeAreaInset(edge: .bottom) { coreBottomInset }
            .onAppear { onAppearHandler() }
            .onDisappear {
                NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
                furiganaTaskHandle?.cancel()
            }

        let inputHandling = base
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
                showToast(editing ? "Edit mode enabled" : "Edit mode disabled")
            }

        let furiganaControls = inputHandling
            .onChange(of: words.words.count) {
                guard incrementalLookupEnabled else { return }
                recomputeSavedWordOverlays()
            }
            .onChange(of: showFurigana) { _, enabled in
                if enabled {
                    // Toggling furigana on should reuse existing segmentation when possible.
                    // Only rebuild the attributed text layer; segmentation is recomputed
                    // inside the pipeline if spans are missing or invalid.
                    triggerFuriganaRefreshIfNeeded(reason: "show furigana toggled on", recomputeSpans: false)
                } else {
                    furiganaTaskHandle?.cancel()
                }
            }
            .onChange(of: wrapLines) { _, enabled in
                showToast(enabled ? "Wrapped lines" : "Single-line layout")
            }
            .onChange(of: alternateTokenColors) { _, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "alternate token colors toggled on" : "alternate token colors toggled off",
                    recomputeSpans: false
                )
                showToast(enabled ? "Alternate token colors enabled" : "Alternate token colors disabled")
            }
            .onChange(of: highlightUnknownTokens) { _, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "unknown highlight toggled on" : "unknown highlight toggled off",
                    recomputeSpans: false
                )
                showToast(enabled ? "Highlight unknown words enabled" : "Highlight unknown words disabled")
            }
            .onChange(of: readingFuriganaSize) {
                triggerFuriganaRefreshIfNeeded(reason: "furigana font size changed", recomputeSpans: false)
            }
            .onChange(of: readingHeadwordSpacingPadding) { _, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "headword spacing padding toggled on" : "headword spacing padding toggled off",
                    recomputeSpans: false
                )
            }
            .onChange(of: knownWordFuriganaModeRaw) { _, _ in
                triggerFuriganaRefreshIfNeeded(reason: "known-word furigana mode changed", recomputeSpans: false)
            }
            .onChange(of: knownWordFuriganaScoreThreshold) { _, _ in
                triggerFuriganaRefreshIfNeeded(reason: "known-word furigana threshold changed", recomputeSpans: false)
            }
            .onChange(of: knownWordFuriganaMinimumReviews) { _, _ in
                triggerFuriganaRefreshIfNeeded(reason: "known-word furigana minimum reviews changed", recomputeSpans: false)
            }

        let selectionHandling = furiganaControls
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
                            if dictionaryPopupLoggingEnabled {
                                CustomLogger.shared.debug(
                                    "DICT show (selection) t=\(ctx.tokenIndex) r=\(r.location)..\(NSMaxRange(r)) s=\(ctx.surface) inline=\(self.inlineDictionaryPanelEnabled) sheet=\(self.sheetDictionaryPanelEnabled)"
                                )
                            }
                        } else {
                            if dictionaryPopupLoggingEnabled {
                                CustomLogger.shared.debug("DICT show (selection)")
                            }
                        }
                    } else {
                        if dictionaryPopupLoggingEnabled {
                            CustomLogger.shared.debug("DICT hide (selection cleared)")
                        }
                    }
                }
                // Tapping a token for dictionary lookup should NOT trigger the sentence-level
                // semantic heatmap (embedding background blocks), which reads as a faint highlight
                // across other tokens.
                if newID != nil {
                    clearSentenceHeatmap()
                }
                handleSelectionLookup()
            }
            .onChange(of: selectionController.persistentSelectionRange) { _, newRange in
                guard incrementalLookupEnabled == false else { return }
                // Do not drive the sentence heatmap off normal selection changes.
                // Sentence selection is handled explicitly by the constellation sheet.
                _ = newRange
            }
            .onChange(of: incrementalSelectedCharacterRange) { _, newRange in
                guard incrementalLookupEnabled else { return }
                // Do not drive the sentence heatmap off normal selection changes.
                _ = newRange
            }
            .onChange(of: sheetSelection?.id) { (_: String?, newID: String?) in
                guard dictionaryPopupEnabled else { return }
                if let _ = newID {
                    if let ctx = sheetSelection {
                        let r = ctx.range
                        if dictionaryPopupLoggingEnabled {
                            CustomLogger.shared.debug(
                                "DICT show (sheet) t=\(ctx.tokenIndex) r=\(r.location)..\(NSMaxRange(r)) s=\(ctx.surface)"
                            )
                        }
                    } else {
                        if dictionaryPopupLoggingEnabled {
                            CustomLogger.shared.debug("DICT show (sheet)")
                        }
                    }
                } else {
                    if dictionaryPopupLoggingEnabled {
                        CustomLogger.shared.debug("DICT hide (sheet cleared)")
                    }
                }
            }

        let noteHandling = selectionHandling
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
            .onChange(of: inputText) { _, _ in
                scheduleLiveSemanticFeedbackIfNeeded()
            }
            .onChange(of: editorSelectedRange?.location) { _, _ in
                scheduleLiveSemanticFeedbackIfNeeded()
            }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    scheduleLiveSemanticFeedbackIfNeeded()
                } else {
                    liveSemanticFeedbackTask?.cancel()
                    liveSemanticFeedback = nil
                }
            }
            .onReceive(readingOverrides.$overrides) { _ in
                handleOverridesExternalChange()
            }

        return noteHandling
            .onChange(of: router.pendingResetNoteID) { _, newValue in
                pendingRouterResetNoteID = newValue
                processPendingRouterResetRequest()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isDictionarySheetPresented {
                    isDictionarySheetPresented = false
                    clearSelection(resetPersistent: true)
                } else if tokenSelection != nil {
                    // Background/whitespace tap clears selection.
                    clearSelection(resetPersistent: false)
                }
            }
            .overlay(alignment: .bottom) {
                if let toastText {
                    Text(toastText)
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }

    private var coreStack: some View {
        ZStack(alignment: .bottom) {
            editorColumn
            inlineDictionaryOverlay
            if debugTokenGeometryOverlay {
                tokenGeometryDebugOverlay
            }
        }
        // Slide in/out ONLY when the panel is shown/hidden.
        // Switching to a new word updates `presented.requestID` but keeps `presented != nil`,
        // so this animation does not run during content swaps.
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: inlineLookup.presented != nil)
        .coordinateSpace(name: Self.coordinateSpaceName)
    }

    @ViewBuilder
    private var tokenGeometryDebugOverlay: some View {
        GeometryReader { proxy in
            ZStack {
                // Outline the coordinate-space container itself.
                Rectangle()
                    .stroke(Color.yellow.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .position(x: proxy.size.width / 2.0, y: proxy.size.height / 2.0)

                // Mark the coordinate-space origin.
                Circle()
                    .fill(Color.yellow.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .position(x: 0, y: 0)

            if let paste = pasteAreaFrame {
                Rectangle()
                    .fill(Color.cyan.opacity(0.06))
                    .frame(width: paste.width, height: paste.height)
                    .position(x: paste.midX, y: paste.midY)

                Rectangle()
                    .stroke(
                        Color.cyan.opacity(0.95),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [14, 10])
                    )
                    .frame(width: paste.width, height: paste.height)
                    .position(x: paste.midX, y: paste.midY)
            }
            if let panel = tokenPanelFrame {
                Rectangle()
                    .stroke(Color.red.opacity(0.9), lineWidth: 2)
                    .frame(width: panel.width, height: panel.height)
                    .position(x: panel.midX, y: panel.midY)
            }

            }
            .allowsHitTesting(false)
        }
    }

    private var editorColumn: some View {
        // Precompute helpers outside of the ViewBuilder to avoid non-View statements inside VStack
        let extraOverlays: [RubyText.TokenOverlay] = incrementalLookupEnabled ? savedWordOverlays : []

        let spanSelectionHandler: ((RubySpanSelection?) -> Void)? = { selection in
            if incrementalLookupEnabled {
                // In incremental lookup mode we still want whitespace taps to clear state.
                guard selection != nil else {
                    incrementalSelectedCharacterRange = nil
                    incrementalLookupTask?.cancel()
                    isIncrementalPopupVisible = false
                    incrementalPopupHits = []
                    return
                }
                return
            }

            handleInlineSpanSelection(selection)
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

        let tokenPanelOverlap: CGFloat = {
            guard inlineDictionaryPanelEnabled else { return 0 }
            guard tokenSelection != nil else { return 0 }
            guard let paste = pasteAreaFrame else { return 0 }
            guard let panel = tokenPanelFrame else { return 0 }
            // Use the panel's height rather than overlap math.
            // In some layouts the panel can ignore safe-area and overlap computations
            // can undercount, making it feel like you "can't scroll to the end".
            return min(max(0, panel.height), paste.height)
        }()

        let viewMetricsContext = RubyText.ViewMetricsContext(
            pasteAreaFrame: pasteAreaFrame,
            tokenPanelFrame: tokenPanelFrame
        )

        return VStack(spacing: 0) {
            FuriganaRenderingHost(
                text: $inputText,
                editorSelectedRange: $editorSelectedRange,
                furiganaText: furiganaAttributedText,
                furiganaSpans: furiganaSpans,
                semanticSpans: furiganaSemanticSpans,
                textSize: readingTextSize,
                isEditing: isEditing,
                showFurigana: incrementalLookupEnabled ? false : showFurigana,
                lineSpacing: readingLineSpacing,
                globalKerningPixels: readingGlobalKerningPixels,
                padHeadwordSpacing: readingHeadwordSpacingPadding,
                wrapLines: wrapLines,
                alternateTokenColors: incrementalLookupEnabled ? false : alternateTokenColors,
                highlightUnknownTokens: incrementalLookupEnabled ? false : highlightUnknownTokens,
                tokenPalette: alternateTokenPalette,
                unknownTokenColor: unknownTokenColor,
                selectedRangeHighlight: incrementalLookupEnabled ? incrementalSelectedCharacterRange : persistentSelectionRange,
                scrollToSelectedRangeToken: constellationScrollToSelectedRangeToken,
                customizedRanges: customizedRanges,
                extraTokenOverlays: extraOverlays,
                enableTapInspection: true,
                bottomObstructionHeight: tokenPanelOverlap,
                onCharacterTap: incrementalLookupEnabled ? { utf16Index in
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
                } : nil,
                onSpanSelection: spanSelectionHandler,
                enableDragSelection: incrementalLookupEnabled ? false : (alternateTokenColors == false),
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
                onContextMenuAction: contextMenuActionHandler,
                viewMetricsContext: viewMetricsContext,
                onDebugTokenListTextChange: { text in
                    // Avoid thrashing SwiftUI state with identical strings.
                    if text != debugTokenListText {
                        debugTokenListText = text
                    }
                }
            )
            .overlay(alignment: .topTrailing) {
                if isEditing, let liveSemanticFeedback {
                    LiveSemanticFeedbackBadge(feedback: liveSemanticFeedback)
                        .padding(.top, 10)
                        .padding(.trailing, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PasteAreaFramePreferenceKey.self,
                        value: proxy.frame(in: .named(Self.coordinateSpaceName))
                    )
                }
            )
            .padding(.vertical, 16)

            HStack(alignment: .center, spacing: 0) {
                ControlCell {
                    Button {
                        hideKeyboard()
                        showToast("Keyboard hidden")
                    } label: {
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
                    if Self.sentenceHeatmapEnabledFlag {
                        Button {
                            hideKeyboard()
                            isConstellationSheetPresented = true
                        } label: {
                            Image(systemName: "circle.dotted")
                                .font(.title2)
                        }
                        .accessibilityLabel("Constellation")
                        .accessibilityHint("View sentence constellation")
                    }
                }

                ControlCell {
                    ZStack {
                        Color.clear.frame(width: 28, height: 28)
                        Image(showFurigana ? "furigana.on" : "furigana.off")
                            .renderingMode(.template)
                            .foregroundColor(.accentColor)
                            .font(.system(size: 22))
                    }
                    .contentShape(Rectangle())
                    .opacity(isEditing ? 0.45 : 1.0)
                    .onTapGesture {
                        guard isEditing == false else { return }
                        showFurigana.toggle()
                        if showFurigana {
                            // Manual toggle should not force a fresh segmentation pass; reuse
                            // existing spans and just rebuild the ruby text.
                            triggerFuriganaRefreshIfNeeded(reason: "manual toggle button", recomputeSpans: false)
                        }
                        showToast(showFurigana ? "Furigana enabled" : "Furigana disabled")
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.35)
                            .onEnded { _ in
                                fireContextMenuHaptic()
                                showingFuriganaOptions = true
                            }
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(showFurigana ? "Disable Furigana" : "Enable Furigana")
                    .accessibilityHint("Double tap to toggle. Press and hold for options.")
                    .popover(
                        isPresented: $showingFuriganaOptions,
                        attachmentAnchor: .rect(.bounds),
                        arrowEdge: .bottom
                    ) {
                        FuriganaOptionsPopover(
                            wrapLines: $wrapLines,
                            alternateTokenColors: $alternateTokenColors,
                            highlightUnknownTokens: $highlightUnknownTokens,
                            padHeadwords: $readingHeadwordSpacingPadding
                        )
                        .presentationCompactAdaptation(.popover)
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
        .sheet(
            isPresented: $isConstellationSheetPresented,
            onDismiss: {
                clearSentenceHeatmap()
            },
            content: {
                if Self.sentenceHeatmapEnabledFlag {
                    SemanticConstellationSheet(
                        sentenceRanges: sentenceRanges,
                        sentenceVectors: sentenceVectors,
                        selectedSentenceIndex: sentenceHeatmapSelectedIndex,
                        onSelectSentence: { range, idx in
                            // Visual-only: select + scroll; do not trigger dictionary lookup.
                            sentenceHeatmapSelectedIndex = idx
                            if let base = furiganaAttributedTextBase {
                                furiganaAttributedText = applySentenceHeatmap(to: base)
                            }
                            if incrementalLookupEnabled {
                                incrementalSelectedCharacterRange = range
                            } else {
                                persistentSelectionRange = range
                            }
                            constellationScrollToSelectedRangeToken &+= 1
                        }
                    )
                    .presentationDetents([.medium, .large])
                } else {
                    EmptyView()
                }
            }
        )
    }

    private func showToast(_ message: String) {
        toastDismissWorkItem?.cancel()
        withAnimation {
            toastText = message
        }

        let currentMessage = message

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            if Task.isCancelled {
                return
            }

            await MainActor.run {
                // Only clear the toast if we're still showing the same message.
                if toastText == currentMessage {
                    withAnimation {
                        toastText = nil
                    }
                }
            }
        }
    }

    private func fireContextMenuHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    private struct FuriganaOptionsPopover: View {
        @Binding var wrapLines: Bool
        @Binding var alternateTokenColors: Bool
        @Binding var highlightUnknownTokens: Bool
        @Binding var padHeadwords: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $wrapLines) {
                    Label("Wrap Lines", systemImage: "text.justify")
                }
                Toggle(isOn: $padHeadwords) {
                    Label("Pad headwords", systemImage: "textformat.size")
                }
                Toggle(isOn: $alternateTokenColors) {
                    Label("Alternate Token Colors", systemImage: "textformat.alt")
                }
                Toggle(isOn: $highlightUnknownTokens) {
                    Label("Highlight Unknown Words", systemImage: "questionmark.square.dashed")
                }
            }
            .toggleStyle(.switch)
            .padding(14)
            .frame(maxWidth: 320)
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
        if debugTokenListText.isEmpty == false {
            return debugTokenListText
        }
        guard let spans = furiganaSpans, spans.isEmpty == false else {
            return "(No spans yet)"
        }
        return describeAdjustedSpansForDebug(spans.map(\.span))
    }

    private func describeAdjustedSpansForDebug(_ spans: [TextSpan]) -> String {
        guard spans.isEmpty == false else { return "" }

        struct DebugSpan {
            let range: NSRange
            let surface: String
        }

        var results: [DebugSpan] = []
        var pendingPrefixSurface = ""
        var pendingPrefixRange: NSRange?

        for span in spans {
            let surface = span.surface
            if isHardBoundaryOnly(surface) {
                if results.isEmpty {
                    pendingPrefixSurface += surface
                    if let existing = pendingPrefixRange {
                        pendingPrefixRange = NSUnionRange(existing, span.range)
                    } else {
                        pendingPrefixRange = span.range
                    }
                } else {
                    let last = results.removeLast()
                    let mergedRange = NSUnionRange(last.range, span.range)
                    results.append(DebugSpan(range: mergedRange, surface: last.surface + surface))
                }
                continue
            }

            if let prefixRange = pendingPrefixRange, pendingPrefixSurface.isEmpty == false {
                let mergedRange = NSUnionRange(prefixRange, span.range)
                results.append(DebugSpan(range: mergedRange, surface: pendingPrefixSurface + surface))
                pendingPrefixSurface = ""
                pendingPrefixRange = nil
            } else {
                results.append(DebugSpan(range: span.range, surface: surface))
            }
        }

        if pendingPrefixSurface.isEmpty == false, let prefixRange = pendingPrefixRange {
            if results.isEmpty {
                results.append(DebugSpan(range: prefixRange, surface: pendingPrefixSurface))
            } else {
                let last = results.removeLast()
                let mergedRange = NSUnionRange(last.range, prefixRange)
                results.append(DebugSpan(range: mergedRange, surface: last.surface + pendingPrefixSurface))
            }
        }

        return results
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
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
                noteID: activeNoteID,
                isReady: (furiganaSemanticSpans.isEmpty == false) || (furiganaSpans != nil),
                isEditing: isEditing,
                selectedRange: tokenSelection?.range ?? persistentSelectionRange,
                hideDuplicateTokens: $hideDuplicateTokens,
                hideCommonParticles: $hideCommonParticles,
                onSelect: { presentDictionaryForSpan(at: $0, focusSplitMenu: false) },
                onGoTo: { goToSpanInNote(at: $0) },
                onAdd: { bookmarkToken(at: $0) },
                onAddAll: { addAllTokensToWordList() },
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
            // Punctuation/whitespace-only spans are useful hard boundaries for segmentation,
            // but not meaningful “words” to extract.
            guard isHardBoundaryOnly(surface) == false else { continue }

            if hideCommonParticles, commonParticleSet.contains(surface) {
                continue
            }

            let preferred = normalizedReading(preferredReading(for: trimmed.range, fallback: semantic.readingKana))
            let key = "\(surface)|\(preferred ?? "")"
            if hideDuplicateTokens, seenKeys.contains(key) {
                continue
            }
            seenKeys.insert(key)

            let displayReading = readingWithOkurigana(surface: surface, baseReading: preferred)
            let alreadySaved = hasSavedWord(surface: surface, reading: preferred, noteID: noteID)
            items.append(
                TokenListItem(
                    spanIndex: index,
                    range: trimmed.range,
                    surface: surface,
                    reading: preferred,
                    displayReading: displayReading,
                    isAlreadySaved: alreadySaved
                )
            )
        }

        return items
    }

    @ToolbarContentBuilder
    private var coreToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                presentTitleEditAlert()
            } label: {
                Text(navigationTitleText)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Title")
            .accessibilityHint("Shows an alert to set the note title")
        }
        ToolbarItem(placement: .topBarLeading) {
            adjustedSpansButton
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 12) {
                // transformPasteTextButton
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
            // Presentation gate:
            // Keep the panel mounted as long as we have a stable `presented` snapshot.
            // When a new lookup starts, `phase` flips to `.resolving`, but `presented`
            // remains unchanged until the next lookup commits. This prevents flicker.
            if let presented = inlineLookup.presented,
               let selection = presented.selection,
               selection.range.length > 0 {
                inlineDismissScrim
                inlineTokenActionPanel(for: selection)
            }
        }
    }

    private var inlineDismissScrim: some View {
        // When the inline dictionary panel is visible, we used to dim the background.
        // That can read as a “faint highlight” across non-selected tokens, so keep it clear.
        // IMPORTANT: keep this scrim non-interactive so it never blocks scrolling.
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
            .zIndex(0.5)
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
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Spacer(minLength: 0)

                let preferred = normalizedReading(preferredReadingForSelection(selection))

                TokenActionPanel(
                    selection: selection,
                    lookup: inlineLookup,
                    preferredReading: preferred,
                    canMergePrevious: canMergeSelection(.previous),
                    canMergeNext: canMergeSelection(.next),
                    onShowDefinitions: {
                        presentWordDefinitions(for: selection)
                    },
                    onDismiss: { clearSelection(resetPersistent: true) },
                    onSaveWord: { entry in
                        toggleSavedWord(surface: selection.surface, preferredReading: preferred, entry: entry)
                    },
                    onApplyReading: { entry in
                        applyDictionaryReading(entry)
                    },
                    onApplyCustomReading: { kana in
                        applyCustomReading(kana)
                    },
                    isWordSaved: { entry in
                        isSavedWord(for: selection.surface, preferredReading: preferred, entry: entry)
                    },
                    onMergePrevious: { mergeSelection(.previous) },
                    onMergeNext: { mergeSelection(.next) },
                    onSplit: { offset in splitSelection(at: offset) },
                    onReset: resetSelectionOverrides,
                    isSelectionCustomized: selectionIsCustomized(selection),
                    enableDragToDismiss: true,
                    embedInMaterialBackground: true,
                    // The inline panel must respect the bottom safe area.
                    // If we let it use the full container height, the action buttons can
                    // end up under the tab bar / home indicator when the panel grows tall.
                    containerHeight: proxy.size.height - proxy.safeAreaInsets.bottom,
                    focusSplitMenu: pendingSplitFocusSelectionID == selection.id,
                    onSplitFocusConsumed: { pendingSplitFocusSelectionID = nil }
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
                            value: proxy.frame(in: .named(Self.coordinateSpaceName))
                        )
                    }
                )
            }
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

        // If token overlay highlighting was enabled in a previous version, disable it once.
        // This avoids the "faint highlight everywhere" look and reduces per-refresh work.
        if didDisableTokenOverlayHighlightingV1 == false {
            if alternateTokenColors || highlightUnknownTokens {
                alternateTokenColors = false
                highlightUnknownTokens = false
            }
            didDisableTokenOverlayHighlightingV1 = true
        }

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

    private func isHardBoundaryOnly(_ surface: String) -> Bool {
        if surface.isEmpty { return true }
        let hardBoundary = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        for scalar in surface.unicodeScalars {
            if hardBoundary.contains(scalar) == false {
                return false
            }
        }
        return true
    }

    private func presentTitleEditAlert() {
        titleEditDraft = noteTitleInput
        isTitleEditAlertPresented = true
    }

    private var titleEditModal: some View {
        ZStack {
            // Tap-to-dismiss scrim.
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture {
                    isTitleEditAlertPresented = false
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("Title", text: $titleEditDraft)
                        .textInputAutocapitalization(.sentences)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                        .onSubmit {
                            applyTitleEditDraft()
                            isTitleEditAlertPresented = false
                        }

                    if titleEditDraft.isEmpty == false {
                        Button {
                            titleEditDraft = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.appTextSecondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear title")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    Button("Cancel", role: .cancel) {
                        isTitleEditAlertPresented = false
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)

                    Button("Set") {
                        applyTitleEditDraft()
                        isTitleEditAlertPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(maxWidth: 520)
            .frame(height: 180)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 24)
            .transition(.scale(scale: 0.98).combined(with: .opacity))
        }
    }

    private func applyTitleEditDraft() {
        let normalized = normalizedTitle(titleEditDraft)

        if normalized == nil {
            hasManuallyEditedTitle = false
            let fallback = inferredTitle(from: inputText)
            noteTitleInput = fallback ?? ""
            if var existing = currentNote {
                existing.title = fallback
                notes.updateNote(existing)
                currentNote = existing
            }
            return
        }

        hasManuallyEditedTitle = true
        noteTitleInput = normalized ?? ""

        if var existing = currentNote {
            existing.title = normalized
            notes.updateNote(existing)
            currentNote = existing
        }
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
            // Reset in one shot so presentation can be gated on `lookup.phase`.
            inlineLookup.reset()
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
        // Guardrail: the dictionary popup is intended for single token-like selections.
        // If the trimmed surface still contains internal whitespace/newlines, treat this
        // as an invalid selection and do not open the popup (multi-span selections like
        // "虹色 もっともっと" should never reach the dictionary).
        if surface.rangeOfCharacter(from: Self.highlightWhitespace) != nil {
            clearSelection()
            return
        }
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

    private func handleSelectionLookup() {
        // INVESTIGATION NOTES (2026-01-04)
        // Dictionary lookup behavior for the popup:
        // - Always routes through DictionaryLookupViewModel.lookup(selectedRange:...)
        // - Ordering is surface → deinflection → STOP (no lemma/reading fallbacks for UI determinism)
        guard let selection = tokenSelection else {
            Task { @MainActor in
                inlineLookup.reset()
            }
            return
        }

        let tokens = furiganaSpans?.map(\.span) ?? []
        let selectedRange = selection.range
        let currentText = inputText
        let selectionID = selection.id
        let lemmaFallbacks = selection.annotatedSpan.lemmaCandidates

        Task { [selection, tokens, selectedRange, currentText, selectionID, lemmaFallbacks] in
            // Treat surface/deinflection + lemma fallbacks as ONE transaction.
            // The UI should not see intermediate empty/loading states.
            await inlineLookup.lookupTransaction(
                requestID: selectionID,
                selection: selection,
                selectedRange: selectedRange,
                inText: currentText,
                tokenSpans: tokens,
                lemmaFallbacks: lemmaFallbacks,
                mode: .japanese
            )
        }
    }

    private func dictionaryPanel(for selection: TokenSelectionContext, enableDragToDismiss: Bool, embedInMaterialBackground: Bool) -> TokenActionPanel {
        let preferred = normalizedReading(preferredReadingForSelection(selection))
        return TokenActionPanel(
            selection: selection,
            lookup: inlineLookup,
            preferredReading: preferred,
            canMergePrevious: canMergeSelection(.previous),
            canMergeNext: canMergeSelection(.next),
            onShowDefinitions: {
                presentWordDefinitions(for: selection)
            },
            onDismiss: { clearSelection(resetPersistent: true) },
            onSaveWord: { entry in
                toggleSavedWord(surface: selection.surface, preferredReading: preferred, entry: entry)
            },
            onApplyReading: { entry in
                applyDictionaryReading(entry)
            },
            onApplyCustomReading: { kana in
                applyCustomReading(kana)
            },
            isWordSaved: { entry in
                isSavedWord(for: selection.surface, preferredReading: preferred, entry: entry)
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

    private func isSavedWord(for surface: String, preferredReading: String?, entry: DictionaryEntry) -> Bool {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return false }
        let noteID = currentNote?.id
        let tokenSurface = kanaFoldToHiragana(s)
        let dictionarySurface = kanaFoldToHiragana(resolvedSurface(from: entry, fallback: s))
        let targetKana = kanaFoldToHiragana(kana)
        let preferredKana = kanaFoldToHiragana(preferredReading)
        return words.words.contains { word in
            guard word.sourceNoteID == noteID else { return false }
            let savedSurface = kanaFoldToHiragana(word.surface)
            let savedDictionarySurface = kanaFoldToHiragana(word.dictionarySurface)
            // New shape: surface matches note token; legacy shape: surface matches dictionary headword.
            guard savedSurface == tokenSurface || savedSurface == dictionarySurface || savedDictionarySurface == dictionarySurface else { return false }
            let savedKana = kanaFoldToHiragana(word.kana)
            if let preferredKana {
                // If the user has applied a custom reading override, treat that as the
                // authoritative “saved” reading for the bookmark state.
                if savedKana == preferredKana { return true }
            }
            return savedKana == targetKana
        }
    }

    private func toggleSavedWord(surface: String, preferredReading: String?, entry: DictionaryEntry) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return }
        let noteID = currentNote?.id

        let tokenSurface = kanaFoldToHiragana(s)
        let dictionarySurface = kanaFoldToHiragana(resolvedSurface(from: entry, fallback: s))
        let targetKana = kanaFoldToHiragana(kana)
        let preferredKana = kanaFoldToHiragana(preferredReading)

        func matchesSavedKey(_ word: Word) -> Bool {
            guard word.sourceNoteID == noteID else { return false }
            let savedSurface = kanaFoldToHiragana(word.surface)
            let savedDictionarySurface = kanaFoldToHiragana(word.dictionarySurface)
            guard savedSurface == tokenSurface || savedSurface == dictionarySurface || savedDictionarySurface == dictionarySurface else { return false }
            let savedKana = kanaFoldToHiragana(word.kana)
            if let preferredKana, savedKana == preferredKana { return true }
            return savedKana == targetKana
        }

        let matchingIDs = Set(
            words.words
                .filter(matchesSavedKey)
                .map(\.id)
        )

        if matchingIDs.isEmpty {
            let meaning = normalizedMeaning(from: entry.gloss)
            guard meaning.isEmpty == false else { return }
            let resolvedDictionarySurface = resolvedSurface(from: entry, fallback: s)
            // If the user has a custom reading override active for this token, save that
            // reading so the words list and bookmark state stay in sync.
            let resolvedKana = normalizedReading(preferredReading) ?? normalizedReading(entry.kana)
            // Store surface as it appears in the note so Extract Words and other token-based
            // UIs can reliably recognize the saved state.
            words.add(surface: s, dictionarySurface: resolvedDictionarySurface, kana: resolvedKana, meaning: meaning, note: nil, sourceNoteID: noteID)
        } else {
            words.delete(ids: matchingIDs)
        }
    }

    private func presentWordDefinitions(for selection: TokenSelectionContext) {
        wordDefinitionsSurface = selection.surface
        wordDefinitionsKana = normalizedReading(preferredReadingForSelection(selection))
        wordDefinitionsLemmaCandidates = selection.annotatedSpan.lemmaCandidates
        wordDefinitionsPartOfSpeech = selection.annotatedSpan.partOfSpeech
        wordDefinitionsContextSentence = SentenceContextExtractor.sentence(containing: selection.range, in: inputText)?.sentence
        wordDefinitionsTokenParts = tokenPartsForSelection(selection)
        showWordDefinitionsSheet = true
    }

    private func tokenPartsForSelection(_ selection: TokenSelectionContext) -> [WordDefinitionsView.TokenPart] {
        let indices = selection.sourceSpanIndices
        guard indices.isEmpty == false else { return [] }
        guard furiganaSemanticSpans.isEmpty == false else { return [] }

        var parts: [WordDefinitionsView.TokenPart] = []
        parts.reserveCapacity(min(8, indices.count))
        var seen: Set<String> = []

        for idx in indices {
            guard furiganaSemanticSpans.indices.contains(idx) else { continue }
            let semantic = furiganaSemanticSpans[idx]
            guard let trimmed = trimmedRangeAndSurface(for: semantic.range) else { continue }
            guard isHardBoundaryOnly(trimmed.surface) == false else { continue }

            let reading = normalizedReading(preferredReading(for: trimmed.range, fallback: semantic.readingKana))
            let key = "\(trimmed.range.location)#\(trimmed.range.length)"
            guard seen.contains(key) == false else { continue }
            seen.insert(key)
            parts.append(.init(id: key, surface: trimmed.surface, kana: reading))
        }

        return parts.count > 1 ? parts : []
    }

    private func preferredReadingForSelection(_ selection: TokenSelectionContext) -> String? {
        preferredReading(for: selection.range, fallback: selection.annotatedSpan.readingKana)
    }

    private func preferredReading(for range: NSRange, fallback: String?) -> String? {
        let overrides = readingOverrides.overrides(for: activeNoteID, overlapping: range)
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
                                let sanitized = sanitizeLength(newValue)
                                // Updating state synchronously from a size preference can create
                                // SwiftUI AttributeGraph cycles (layout -> preference -> state -> layout).
                                // Defer to the next run loop to break the cycle.
                                if abs(measuredSheetHeight - sanitized) > 0.5 {
                                    DispatchQueue.main.async {
                                        sheetPanelHeight = sanitized
                                        measuredSheetHeight = sanitized
                                    }
                                }
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
            GeometryReader { proxy in
                let containerFrame = proxy.frame(in: .named(Self.coordinateSpaceName))
                let localPaste: CGRect? = pasteAreaFrame.map { paste in
                    CGRect(
                        x: paste.minX - containerFrame.minX,
                        y: paste.minY - containerFrame.minY,
                        width: paste.width,
                        height: paste.height
                    )
                }
                let regions = legacyDismissHitRegions(containerSize: proxy.size, localPaste: localPaste)

                ZStack {
                    ForEach(Array(regions.enumerated()), id: \.offset) { _, rect in
                        // IMPORTANT: UIKit ignores views with alpha <= 0.01 for hit-testing.
                        Color.black.opacity(0.02)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                clearSelection(resetPersistent: false)
                            }
                    }
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
            .zIndex(0.5)
        }
    }

    private func legacyDismissHitRegions(containerSize: CGSize, localPaste: CGRect?) -> [CGRect] {
        let container = CGRect(origin: .zero, size: containerSize)
        guard let paste = localPaste?.intersection(container),
              paste.isNull == false,
              paste.isEmpty == false else {
            return container.size.width > 0 && container.size.height > 0 ? [container] : []
        }

        var regions: [CGRect] = []

        if paste.minY > container.minY {
            let height = paste.minY - container.minY
            regions.append(CGRect(x: container.minX, y: container.minY, width: container.width, height: height))
        }
        if paste.maxY < container.maxY {
            let height = container.maxY - paste.maxY
            regions.append(CGRect(x: container.minX, y: paste.maxY, width: container.width, height: height))
        }
        if paste.minX > container.minX {
            let width = paste.minX - container.minX
            regions.append(CGRect(x: container.minX, y: paste.minY, width: width, height: paste.height))
        }
        if paste.maxX < container.maxX {
            let width = container.maxX - paste.maxX
            regions.append(CGRect(x: paste.maxX, y: paste.minY, width: width, height: paste.height))
        }

        return regions.filter { $0.width > 1 && $0.height > 1 }
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
        // Ignore punctuation/whitespace selections (e.g. "," "、" "。"),
        // which are useful as hard boundaries but not meaningful lookup terms.
        guard isHardBoundaryOnly(trimmed.surface) == false else { return nil }
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
        guard let context = selectionContext(forSpanAt: index) else {
            clearSelection(resetPersistent: true)
            return
        }

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
            if dictionaryPopupLoggingEnabled {
                let r = context.range
                CustomLogger.shared.debug(
                    "DICT show (tap) t=\(index) r=\(r.location)..\(NSMaxRange(r)) s=\(context.surface) inline=\(self.inlineDictionaryPanelEnabled) sheet=\(self.sheetDictionaryPanelEnabled)"
                )
            }
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
        let reading = normalizedReading(preferredReading(for: context.range, fallback: context.semanticSpan.readingKana))
        let surface = context.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteID = currentNote?.id

        func matchesSavedKey(_ word: Word) -> Bool {
            guard word.sourceNoteID == noteID else { return false }
            guard kanaFoldToHiragana(word.surface) == kanaFoldToHiragana(surface) else { return false }
            // If we don't know the token's reading (common when we haven't attached readings
            // for this token), treat reading as a wildcard so the star can still toggle.
            if let foldedReading = kanaFoldToHiragana(reading) {
                return kanaFoldToHiragana(word.kana) == foldedReading
            }
            return true
        }

        // Toggle behavior: if already saved, delete; otherwise add
        if hasSavedWord(surface: surface, reading: reading, noteID: noteID) {
            let matches = words.words.filter(matchesSavedKey)
            let ids = Set(matches.map { $0.id })
            if ids.isEmpty == false {
                words.delete(ids: ids)
            }
            return
        }

        Task {
            let entry = await lookupPreferredDictionaryEntry(
                surface: surface,
                reading: reading,
                lemmaCandidates: context.annotatedSpan.lemmaCandidates
            )

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
                // Save with the preferred reading (custom override) when present.
                let kana = reading ?? normalizedReading(entry.kana)
                let resolvedDictionarySurface = resolvedSurface(from: entry, fallback: context.surface)
                words.add(surface: surface, dictionarySurface: resolvedDictionarySurface, kana: kana, meaning: meaning, note: nil, sourceNoteID: noteID)
            }
        }
    }

    private func addAllTokensToWordList() {
        let items = tokenListItems
        guard items.isEmpty == false else {
            showToast("No tokens to add")
            return
        }

        let candidates = items.filter { $0.isAlreadySaved == false }
        guard candidates.isEmpty == false else {
            showToast("All words already saved")
            return
        }

        showToast("Saving…")
        let noteID = currentNote?.id

        Task {
            var batch: [WordsStore.WordToAdd] = []
            batch.reserveCapacity(candidates.count)

            for item in candidates {
                let surface = item.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }

                let reading = normalizedReading(item.reading)
                let lemmaCandidates = selectionContext(forSpanAt: item.spanIndex)?.annotatedSpan.lemmaCandidates ?? []
                let entry = await lookupPreferredDictionaryEntry(
                    surface: surface,
                    reading: reading,
                    lemmaCandidates: lemmaCandidates
                )
                guard let entry else { continue }

                let meaning = normalizedMeaning(from: entry.gloss)
                guard meaning.isEmpty == false else { continue }

                let kana = reading ?? normalizedReading(entry.kana)
                let dictionarySurface = resolvedSurface(from: entry, fallback: surface)
                let payload = WordsStore.WordToAdd(
                    surface: surface,
                    dictionarySurface: dictionarySurface,
                    kana: kana,
                    meaning: meaning,
                    note: nil
                )
                batch.append(payload)
            }

            await MainActor.run {
                if batch.isEmpty {
                    showToast("No dictionary matches")
                } else {
                    words.addMany(batch, sourceNoteID: noteID)
                    showToast("Saved \(batch.count) words")
                }
            }
        }
    }

    private func lookupPreferredDictionaryEntry(surface: String, reading: String?, lemmaCandidates: [String] = []) async -> DictionaryEntry? {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = normalizedReading(reading)
        let normalizedLemmas = lemmaCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        let store = DictionarySQLiteStore.shared
        let lookupLimit = 30

        var terms: [String] = []
        if normalizedSurface.isEmpty == false { terms.append(normalizedSurface) }
        for lemma in normalizedLemmas where terms.contains(lemma) == false {
            terms.append(lemma)
        }
        if let desired = normalizedReading, desired.isEmpty == false, terms.contains(desired) == false {
            // Reading-only fallback (useful when the surface is inflected or otherwise not in JMdict).
            terms.append(desired)
        }

        guard terms.isEmpty == false else { return nil }

        var candidatesByID: [Int64: DictionaryEntry] = [:]
        for term in terms {
            if let rows = try? await store.lookup(term: term, limit: lookupLimit), rows.isEmpty == false {
                for row in rows {
                    candidatesByID[row.entryID] = row
                }
            }
        }

        var candidates = Array(candidatesByID.values)
        guard candidates.isEmpty == false else { return nil }

        // If we know the token's reading, require it for auto-picks.
        if let desired = normalizedReading {
            let filtered = candidates.filter { entryMatchesReading($0, reading: desired) }
            if filtered.isEmpty == false {
                candidates = filtered
            }
        }

        let entryIDs = Array(Set(candidates.map { $0.entryID }))
        let priority = (try? await store.fetchEntryPriorityScores(for: entryIDs)) ?? [:]
        let details = (try? await store.fetchEntryDetails(for: entryIDs)) ?? []
        let detailsByID: [Int64: DictionaryEntryDetail] = details.reduce(into: [:]) { partialResult, detail in
            partialResult[detail.entryID] = detail
        }

        return DictionaryEntryResolver.chooseBest(
            surface: normalizedSurface,
            reading: normalizedReading,
            candidates: candidates,
            detailsByEntryID: detailsByID,
            entryPriority: priority
        )
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
            // If we don't know the reading for this token, match on surface alone.
            // This keeps the Extract Words star button reliable (no "can't bookmark" feeling).
            if let targetKana {
                return kanaFoldToHiragana(word.kana) == targetKana
            }
            return true
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
        guard let mergeRange = stage1MergeRange(forSemanticIndex: index, direction: direction) else { return }
        let union: NSRange? = {
            if propagateTokenEdits {
                return applySpanMergeEverywhere(mergeRange: mergeRange, actionName: "Merge Tokens")
            }
            return applySpanMerge(mergeRange: mergeRange, actionName: "Merge Tokens")
        }()
        guard let union else { return }
        persistentSelectionRange = union
        pendingSelectionRange = union
        let mergedIndex = mergeRange.lowerBound
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
        stage1MergeRange(forSemanticIndex: index, direction: direction) != nil
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

        let tokenSurface = selection.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenSurface.isEmpty == false else { return }

        let tokenSuffix = trailingKanaSuffix(in: tokenSurface)

        let lemmaSurface: String = {
            let kanji = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
            if kanji.isEmpty == false { return kanji }
            let kana = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return kana
        }()

        let lemmaSuffix = trailingKanaSuffix(in: lemmaSurface)
        let baseReading = (entry.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Heuristic: if both lemma and token have okurigana, treat the lemma's okurigana
        // as a suffix in the reading and swap it for the token's okurigana.
        // Example: 抱く(だく) -> 抱かれ(だかれ)
        let surfaceReading: String = {
            guard baseReading.isEmpty == false else { return "" }
            guard let tokenSuffix, tokenSuffix.isEmpty == false else { return baseReading }
            guard let lemmaSuffix, lemmaSuffix.isEmpty == false else { return baseReading }
            guard baseReading.hasSuffix(lemmaSuffix) else { return baseReading }
            let stem = String(baseReading.dropLast(lemmaSuffix.count))
            return stem + tokenSuffix
        }()

        // Store only the kanji reading portion for mixed kanji-kana tokens so ruby
        // can render like 抱(だ)かれ instead of treating the whole surface as ruby.
        let overrideKana: String = {
            guard let tokenSuffix, tokenSuffix.isEmpty == false else { return surfaceReading }
            guard surfaceReading.hasSuffix(tokenSuffix) else { return surfaceReading }
            let storage = tokenSurface as NSString
            // If the token is entirely kana, don't strip; it would produce empty.
            if isKanaOnlySurface(tokenSurface) { return surfaceReading }
            // Ensure there is at least one non-kana scalar before stripping.
            if storage.length <= tokenSuffix.utf16.count { return surfaceReading }
            return String(surfaceReading.dropLast(tokenSuffix.count))
        }()

        let trimmedKana = overrideKana.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let mergeRange = stage1MergeRange(forSemanticIndex: selection.tokenIndex, direction: direction) else { return }
        let union: NSRange? = {
            if propagateTokenEdits {
                return applySpanMergeEverywhere(mergeRange: mergeRange, actionName: "Merge Tokens")
            }
            return applySpanMerge(mergeRange: mergeRange, actionName: "Merge Tokens")
        }()
        guard let union else { return }
        persistentSelectionRange = union
        pendingSelectionRange = union
        pendingSplitFocusSelectionID = nil

        let mergedIndex = mergeRange.lowerBound
        let textStorage = inputText as NSString
        guard NSMaxRange(union) <= textStorage.length else { return }
        let surface = textStorage.substring(with: union)
        let semantic = SemanticSpan(range: union, surface: surface, sourceSpanIndices: mergedIndex..<(mergedIndex + 1), readingKana: nil)
        let ephemeral = AnnotatedSpan(span: TextSpan(range: union, surface: surface, isLexiconMatch: false), readingKana: nil, lemmaCandidates: [])
        let ctx = TokenSelectionContext(tokenIndex: mergedIndex, range: union, surface: surface, semanticSpan: semantic, sourceSpanIndices: semantic.sourceSpanIndices, annotatedSpan: ephemeral)
        tokenSelection = ctx

        // Keep the Extract Words sheet's in-sheet dictionary panel in sync.
        if wasShowingTokensPopover {
            sheetSelection = ctx
        }
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

        // Keep the dictionary panel updated after the split by restoring selection to one of the
        // resulting token ranges (smallest side; tie-break to the right).
        let baseRange = selection.range
        if baseRange.location != NSNotFound, baseRange.length > 1 {
            let baseStart = baseRange.location
            let baseEnd = NSMaxRange(baseRange)
            let leftLen = splitUTF16Index - baseStart
            let rightLen = baseEnd - splitUTF16Index
            if leftLen > 0, rightLen > 0 {
                let leftRange = NSRange(location: baseStart, length: leftLen)
                let rightRange = NSRange(location: splitUTF16Index, length: rightLen)
                let target = (rightLen <= leftLen) ? rightRange : leftRange
                pendingSelectionRange = target
                persistentSelectionRange = target
            }
        }

        // Clear the current selection now (it may no longer correspond to a single token), but
        // keep `pendingSelectionRange` so we can restore after recompute.
        tokenSelection = nil
        if sheetDictionaryPanelEnabled || showTokensPopover {
            sheetSelection = nil
        }
        pendingSplitFocusSelectionID = nil

        // If the split creates a 1-character prefix/suffix, explicitly lock the *outer* edge too.
        // Otherwise Stage-2.5 may legitimately regroup that 1-char token into its neighbor
        // (e.g. splitting “…か” right before “ら” can immediately become “から”).
        let selectionStart = selection.range.location
        let selectionEnd = NSMaxRange(selection.range)
        let leftLen = splitUTF16Index - selectionStart
        let rightLen = selectionEnd - splitUTF16Index
        if leftLen == 1 {
            tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: selectionStart, text: inputText)
        }
        if rightLen == 1 {
            tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: selectionEnd, text: inputText)
        }
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
            if propagateTokenEdits {
                applyHardCutEverywhere(splitUTF16Index: splitUTF16Index)
            } else {
                tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: splitUTF16Index, text: inputText)
            }
            triggerFuriganaRefreshIfNeeded(reason: "Split Token", recomputeSpans: true)
            return
        }

        guard let spanIndex = stage1Index, stage1.indices.contains(spanIndex) else { return }
        let spanRange = stage1[spanIndex].span.range
        let localOffset = splitUTF16Index - spanRange.location

        if localOffset <= 0 || localOffset >= spanRange.length {
            if propagateTokenEdits {
                applyHardCutEverywhere(splitUTF16Index: splitUTF16Index)
            } else {
                tokenBoundaries.addHardCut(noteID: activeNoteID, utf16Index: splitUTF16Index, text: inputText)
            }
            triggerFuriganaRefreshIfNeeded(reason: "Split Token", recomputeSpans: true)
            return
        }

        if propagateTokenEdits {
            applySpanSplitEverywhere(range: spanRange, offset: localOffset, actionName: "Split Token")
        } else {
            applySpanSplit(spanIndex: spanIndex, range: spanRange, offset: localOffset, actionName: "Split Token")
        }
    }

    private func applySpanMergeEverywhere(mergeRange: Range<Int>, actionName: String) -> NSRange? {
        guard let spans = furiganaSpans else { return nil }
        guard mergeRange.count >= 2 else { return nil }
        guard mergeRange.lowerBound >= 0, mergeRange.upperBound <= spans.count else { return nil }

        let baseSpans = spans.map(\.span)
        let pattern: [String] = mergeRange.map { baseSpans[$0].surface }
        guard pattern.isEmpty == false else { return nil }

        // Selected union (used to keep selection stable).
        var selectedUnion = baseSpans[mergeRange.lowerBound].range
        for i in mergeRange.dropFirst() {
            selectedUnion = NSUnionRange(selectedUnion, baseSpans[i].range)
        }

        let nsText = inputText as NSString
        guard selectedUnion.location != NSNotFound, selectedUnion.length > 0 else { return nil }
        guard NSMaxRange(selectedUnion) <= nsText.length else { return nil }

        func matches(at i: Int) -> Bool {
            guard i >= 0 else { return false }
            guard i + pattern.count <= baseSpans.count else { return false }
            for j in 0..<pattern.count {
                let a = baseSpans[i + j]
                if a.surface != pattern[j] { return false }
                if j > 0 {
                    let prev = baseSpans[i + j - 1]
                    if NSMaxRange(prev.range) != a.range.location { return false }
                }
            }
            return true
        }

        var newSpans: [TextSpan] = []
        newSpans.reserveCapacity(baseSpans.count)

        var i = 0
        while i < baseSpans.count {
            if matches(at: i) {
                var union = baseSpans[i].range
                for j in 1..<pattern.count {
                    union = NSUnionRange(union, baseSpans[i + j].range)
                }
                if union.location != NSNotFound, union.length > 0, NSMaxRange(union) <= nsText.length {
                    let mergedSurface = nsText.substring(with: union)
                    newSpans.append(TextSpan(range: union, surface: mergedSurface, isLexiconMatch: false))
                    i += pattern.count
                    continue
                }
            }

            newSpans.append(baseSpans[i])
            i += 1
        }

        replaceSpans(newSpans, actionName: actionName)
        return selectedUnion
    }

    private func applySpanSplitEverywhere(range: NSRange, offset: Int, actionName: String) {
        guard let spans = furiganaSpans else { return }
        guard range.length > 1 else { return }
        guard offset > 0, offset < range.length else { return }

        let nsText = inputText as NSString
        guard nsText.length > 0 else { return }
        guard NSMaxRange(range) <= nsText.length else { return }

        let targetSurface = nsText.substring(with: range)
        guard targetSurface.isEmpty == false else { return }

        let baseSpans = spans.map(\.span)
        var newSpans: [TextSpan] = []
        newSpans.reserveCapacity(baseSpans.count + 16)

        for span in baseSpans {
            if span.surface == targetSurface, span.range.length > 1, offset > 0, offset < span.range.length {
                let leftRange = NSRange(location: span.range.location, length: offset)
                let rightRange = NSRange(location: span.range.location + offset, length: span.range.length - offset)
                if leftRange.length > 0, rightRange.length > 0, NSMaxRange(rightRange) <= nsText.length {
                    let leftSurface = nsText.substring(with: leftRange)
                    let rightSurface = nsText.substring(with: rightRange)
                    newSpans.append(TextSpan(range: leftRange, surface: leftSurface, isLexiconMatch: false))
                    newSpans.append(TextSpan(range: rightRange, surface: rightSurface, isLexiconMatch: false))
                    continue
                }
            }
            newSpans.append(span)
        }

        replaceSpans(newSpans, actionName: actionName)
    }

    private func applyHardCutEverywhere(splitUTF16Index: Int) {
        let noteID = activeNoteID
        let text = inputText
        guard let spans = furiganaSpans?.map(\.span), spans.isEmpty == false else {
            tokenBoundaries.addHardCut(noteID: noteID, utf16Index: splitUTF16Index, text: text)
            return
        }

        // Identify the boundary's left/right token surfaces.
        var leftSurface: String? = nil
        var rightSurface: String? = nil
        for i in 0..<(spans.count - 1) {
            let a = spans[i]
            let b = spans[i + 1]
            if NSMaxRange(a.range) == splitUTF16Index, b.range.location == splitUTF16Index {
                leftSurface = a.surface
                rightSurface = b.surface
                break
            }
        }

        guard let leftSurface, let rightSurface else {
            tokenBoundaries.addHardCut(noteID: noteID, utf16Index: splitUTF16Index, text: text)
            return
        }

        var indices: [Int] = []
        indices.reserveCapacity(32)
        for i in 0..<(spans.count - 1) {
            let a = spans[i]
            let b = spans[i + 1]
            guard a.surface == leftSurface, b.surface == rightSurface else { continue }
            let boundary = NSMaxRange(a.range)
            guard boundary == b.range.location else { continue }
            indices.append(boundary)
        }

        if indices.isEmpty {
            tokenBoundaries.addHardCut(noteID: noteID, utf16Index: splitUTF16Index, text: text)
        } else {
            tokenBoundaries.addHardCuts(noteID: noteID, utf16Indices: indices, text: text)
        }
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

    private func applySpanMerge(mergeRange: Range<Int>, actionName: String) -> NSRange? {
        guard let spans = furiganaSpans else { return nil }
        guard mergeRange.count >= 2 else { return nil }
        guard mergeRange.lowerBound >= 0, mergeRange.upperBound <= spans.count else { return nil }

        var union = spans[mergeRange.lowerBound].span.range
        for i in mergeRange.dropFirst() {
            union = NSUnionRange(union, spans[i].span.range)
        }

        let nsText = inputText as NSString
        guard union.location != NSNotFound, union.length > 0 else { return nil }
        guard NSMaxRange(union) <= nsText.length else { return nil }
        let mergedSurface = nsText.substring(with: union)

        var newSpans = spans.map(\.span)
        newSpans.removeSubrange(mergeRange)
        newSpans.insert(TextSpan(range: union, surface: mergedSurface, isLexiconMatch: false), at: mergeRange.lowerBound)

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
        return stage1MergeRange(forSemanticIndex: selection.tokenIndex, direction: direction) != nil
    }

    private func stage1MergeRange(forSemanticIndex index: Int, direction: MergeDirection) -> Range<Int>? {
        guard let stage1 = furiganaSpans else { return nil }
        guard furiganaSemanticSpans.indices.contains(index) else { return nil }
        let semantic = furiganaSemanticSpans[index]

        let lower = semantic.sourceSpanIndices.lowerBound
        let upper = semantic.sourceSpanIndices.upperBound
        guard lower >= 0, upper <= stage1.count else { return nil }

        switch direction {
        case .previous:
            let neighbor = lower - 1
            guard stage1.indices.contains(neighbor) else { return nil }
            return neighbor..<upper
        case .next:
            let neighbor = upper
            guard stage1.indices.contains(neighbor) else { return nil }
            return lower..<(neighbor + 1)
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
        guard inputText.isEmpty == false else { return }
        furiganaRefreshToken &+= 1
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
        guard inputText.isEmpty == false else { return nil }

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
        let currentHeadwordSpacingPadding = readingHeadwordSpacingPadding

        let knownWordSurfaceKeys: Set<String> = {
            let mode = FuriganaKnownWordMode(rawValue: knownWordFuriganaModeRaw) ?? .off
            guard mode != .off else { return [] }

            var out: Set<String> = []
            out.reserveCapacity(min(4096, words.words.count * 2))

            func insertWordKeys(_ w: Word) {
                let s = w.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty == false { out.insert(kanaFoldToHiragana(s)) }
                if let ds = w.dictionarySurface?.trimmingCharacters(in: .whitespacesAndNewlines), ds.isEmpty == false {
                    out.insert(kanaFoldToHiragana(ds))
                }
            }

            switch mode {
            case .off:
                return []
            case .saved:
                for w in words.words {
                    insertWordKeys(w)
                }
            case .learned:
                let threshold = max(0.0, min(1.0, knownWordFuriganaScoreThreshold))
                let minReviews = max(1, knownWordFuriganaMinimumReviews)
                for w in words.words {
                    if let score = ReviewPersistence.learnedScore(for: w.id, minimumReviews: minReviews), score >= threshold {
                        insertWordKeys(w)
                    }
                }
            }

            return out
        }()

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
            context: "PasteView",
            padHeadwordSpacing: currentHeadwordSpacingPadding,
            knownWordSurfaceKeys: knownWordSurfaceKeys
        )
        let service = furiganaPipeline
        return {
            let result = await service.render(pipelineInput)
            await MainActor.run {
                guard Task.isCancelled == false else {
                    return
                }
                guard token == furiganaRefreshToken else {
                    return
                }
                guard inputText == currentText else {
                    return
                }
                furiganaSpans = result.spans
                furiganaSemanticSpans = result.semanticSpans
                if showFurigana == currentShowFurigana {
                    let base = result.attributedString ?? NSAttributedString(string: currentText)
                    furiganaAttributedTextBase = base
                    furiganaAttributedText = applySentenceHeatmap(to: base)
                } else if showFurigana == false {
                    let base = NSAttributedString(string: currentText)
                    furiganaAttributedTextBase = base
                    furiganaAttributedText = applySentenceHeatmap(to: base)
                }
                restoreSelectionIfNeeded()
                startSentenceHeatmapPrecomputeIfPossible(text: currentText, spans: result.spans)
            }
        }
    }

    // MARK: - Sentence semantic heatmap

    private func updateSentenceHeatmapSelection(for selectedRange: NSRange?) {
        guard let base = furiganaAttributedTextBase else {
            // Rendering not ready yet; just record state.
            sentenceHeatmapSelectedIndex = nil
            return
        }

        guard let selectedRange, sentenceRanges.isEmpty == false else {
            sentenceHeatmapSelectedIndex = nil
            furiganaAttributedText = base
            return
        }

        let idx = sentenceRanges.firstIndex(where: { NSLocationInRange(selectedRange.location, $0) })
        if idx == sentenceHeatmapSelectedIndex {
            return
        }

        sentenceHeatmapSelectedIndex = idx
        if idx == nil {
            furiganaAttributedText = base
        } else {
            furiganaAttributedText = applySentenceHeatmap(to: base)
        }
    }

    private func startSentenceHeatmapPrecomputeIfPossible(text: String, spans: [AnnotatedSpan]?) {
        guard Self.sentenceHeatmapEnabledFlag else {
            sentenceHeatmapTask?.cancel()
            sentenceVectors = []
            sentenceRanges = []
            clearSentenceHeatmap()
            return
        }

        let nsText = text as NSString
        let ranges = SentenceRangeResolver.sentenceRanges(in: nsText)
        sentenceRanges = ranges

        // Do not infer heatmap selection from the current selection range; that makes
        // dictionary taps paint background blocks across other tokens.
        if sentenceHeatmapSelectedIndex == nil, let base = furiganaAttributedTextBase {
            furiganaAttributedText = base
        }

        guard let spans, spans.isEmpty == false, ranges.isEmpty == false else {
            sentenceVectors = []
            return
        }

        sentenceHeatmapTask?.cancel()
        let capturedRanges = ranges
        let capturedSpans = spans
        sentenceHeatmapTask = Task(priority: .utility) {
            // Resolve EmbeddingAccess safely.
            let access = await MainActor.run(resultType: EmbeddingAccess.self, body: { EmbeddingAccess.shared })

            // Bucket spans by sentence.
            var tokenBuckets: [[EmbeddingToken]] = Array(repeating: [], count: capturedRanges.count)
            tokenBuckets.reserveCapacity(capturedRanges.count)

            var sentenceIndex = 0
            for s in capturedSpans {
                let r = s.span.range
                guard r.location != NSNotFound, r.length > 0 else { continue }

                // Fast path: spans are typically in ascending order.
                if sentenceIndex < capturedRanges.count {
                    while sentenceIndex < capturedRanges.count,
                          NSMaxRange(capturedRanges[sentenceIndex]) <= r.location {
                        sentenceIndex += 1
                    }
                }

                let resolvedSentenceIndex: Int?
                if sentenceIndex < capturedRanges.count,
                   NSLocationInRange(r.location, capturedRanges[sentenceIndex]) {
                    resolvedSentenceIndex = sentenceIndex
                } else {
                    // Fallback (should be rare): handle out-of-order spans.
                    resolvedSentenceIndex = capturedRanges.firstIndex(where: { NSLocationInRange(r.location, $0) })
                }

                guard let sentenceIndex = resolvedSentenceIndex else { continue }
                let lemma = s.lemmaCandidates.first
                let token = EmbeddingToken(surface: s.span.surface, lemma: lemma, reading: s.readingKana)
                tokenBuckets[sentenceIndex].append(token)
            }

            // Collect all unique candidate keys for batch fetch.
            var unique: [String] = []
            unique.reserveCapacity(capturedSpans.count * 2)
            var seen: Set<String> = []
            seen.reserveCapacity(capturedSpans.count * 2)

            let perSentenceCandidates: [[[String]]] = tokenBuckets.map { bucket in
                bucket.map { EmbeddingFallbackPolicy.candidates(for: $0) }
            }

            for sentence in perSentenceCandidates {
                for tokenCandidates in sentence {
                    for c in tokenCandidates {
                        if c.isEmpty { continue }
                        if seen.insert(c).inserted {
                            unique.append(c)
                        }
                    }
                }
            }

            let fetched = access.vectors(for: unique)

            func normalize(_ v: [Float]) -> [Float] {
                var sum: Float = 0
                for x in v { sum += x * x }
                let norm = sum.squareRoot()
                guard norm > 0 else { return v }
                return v.map { $0 / norm }
            }

            var vectors: [[Float]?] = Array(repeating: nil, count: capturedRanges.count)

            for (i, sentence) in perSentenceCandidates.enumerated() {
                var acc: [Float]? = nil
                var count: Float = 0
                for tokenCandidates in sentence {
                    var chosen: [Float]? = nil
                    for c in tokenCandidates {
                        if let v = fetched[c] {
                            chosen = v
                            break
                        }
                    }
                    guard let vec = chosen else { continue }

                    if acc == nil {
                        acc = Array(repeating: 0, count: vec.count)
                    }
                    guard var a = acc else { continue }
                    for j in 0..<vec.count {
                        a[j] += vec[j]
                    }
                    acc = a
                    count += 1
                }

                if let acc, count > 0 {
                    let mean = acc.map { $0 / count }
                    vectors[i] = normalize(mean)
                }
            }

            await MainActor.run {
                guard Task.isCancelled == false else { return }
                sentenceVectors = vectors
                // Re-apply heatmap with fresh vectors if a selection is active.
                if let base = furiganaAttributedTextBase {
                    furiganaAttributedText = applySentenceHeatmap(to: base)
                }
            }
        }
    }

    private func applySentenceHeatmap(to base: NSAttributedString?) -> NSAttributedString? {
        guard let base else { return nil }
        guard Self.sentenceHeatmapEnabledFlag else { return base }
        // Heatmap is a semantic exploration visual; don't show it during dictionary popup.
        guard tokenSelection == nil else { return base }
        guard let selectedIndex = sentenceHeatmapSelectedIndex else { return base }
        guard sentenceRanges.isEmpty == false, sentenceVectors.count == sentenceRanges.count else { return base }
        guard sentenceVectors.indices.contains(selectedIndex), let selectedVec = sentenceVectors[selectedIndex] else { return base }

        // Compute similarities (dot product) and map to background colors.
        var sims: [Float] = Array(repeating: 0, count: sentenceRanges.count)
        for i in 0..<sentenceRanges.count {
            guard let v = sentenceVectors[i] else {
                sims[i] = 0
                continue
            }
            sims[i] = EmbeddingMath.cosineSimilarity(a: selectedVec, b: v)
        }

        let mutable = NSMutableAttributedString(attributedString: base)
        // Remove any existing heatmap backgrounds (only within sentence ranges).
        for r in sentenceRanges {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= mutable.length else { continue }
            mutable.removeAttribute(.backgroundColor, range: r)
        }

        func clamp01(_ x: Float) -> CGFloat {
            CGFloat(max(0, min(1, x)))
        }

        func heatColor(sim: Float, isSelected: Bool) -> UIColor {
            // Convert [-1,1] -> [0,1], but we mostly expect [0,1].
            let t = clamp01((sim + 1) * 0.5)
            // Low similarity = light gray; high similarity = warm.
            let baseGray = UIColor.systemGray5
            let warm = UIColor.systemOrange

            let alpha: CGFloat = isSelected ? 0.28 : (0.04 + 0.18 * t)
            return blend(base: baseGray, top: warm, t: t).withAlphaComponent(alpha)
        }

        for i in 0..<sentenceRanges.count {
            let r = sentenceRanges[i]
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= mutable.length else { continue }
            let color = heatColor(sim: sims[i], isSelected: i == selectedIndex)
            mutable.addAttribute(.backgroundColor, value: color, range: r)
        }

        return mutable
    }

    private func blend(base: UIColor, top: UIColor, t: CGFloat) -> UIColor {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        let u = max(0, min(1, t))
        return UIColor(
            red: br + (tr - br) * u,
            green: bg + (tg - bg) * u,
            blue: bb + (tb - bb) * u,
            alpha: 1
        )
    }

    private func clearSentenceHeatmap() {
        sentenceHeatmapSelectedIndex = nil
        if let base = furiganaAttributedTextBase {
            furiganaAttributedText = base
        }
    }

    struct LiveSemanticFeedback: Equatable {
        let previousSimilarity: Float?
        let paragraphSimilarity: Float?
        let displaySentenceIndex: Int
    }

    private func scheduleLiveSemanticFeedbackIfNeeded() {
        guard isEditing else { return }
        guard incrementalLookupEnabled == false else {
            liveSemanticFeedback = nil
            return
        }

        liveSemanticFeedbackTask?.cancel()

        let capturedText = inputText
        let capturedCaretRange = editorSelectedRange
        let capturedSentenceRanges = sentenceRanges
        let capturedSentenceVectors = sentenceVectors

        liveSemanticFeedbackTask = Task(priority: .utility) {
            // Debounce: don't run on every keystroke.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard Task.isCancelled == false else { return }

            let nsText = capturedText as NSString
            guard nsText.length > 0 else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard let caret = capturedCaretRange else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            let caretLoc = max(0, min(caret.location, max(0, nsText.length - 1)))

            let ranges: [NSRange] = capturedSentenceRanges.isEmpty
                ? SentenceRangeResolver.sentenceRanges(in: nsText)
                : capturedSentenceRanges

            guard ranges.isEmpty == false else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard let sentenceIndex = ranges.firstIndex(where: { NSLocationInRange(caretLoc, $0) }) else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard capturedSentenceVectors.count == ranges.count else {
                // Embeddings not ready for this text yet.
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            guard let current = capturedSentenceVectors[sentenceIndex] else {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            let prevSim: Float? = {
                guard sentenceIndex > 0 else { return nil }
                guard let prev = capturedSentenceVectors[sentenceIndex - 1] else { return nil }
                return EmbeddingMath.cosineSimilarity(a: current, b: prev)
            }()

            let paragraph = paragraphRange(containingUTF16: caretLoc, in: nsText)
            let paraIndices = ranges.indices.filter { NSIntersectionRange(ranges[$0], paragraph).length > 0 }

            let paraSim: Float? = {
                // Exclude current sentence when possible.
                let withoutCurrent = paraIndices.filter { $0 != sentenceIndex }
                let source = withoutCurrent.isEmpty ? paraIndices : withoutCurrent
                guard source.count > 0 else { return nil }

                var acc: [Float]? = nil
                var count: Float = 0
                for idx in source {
                    guard let v = capturedSentenceVectors[idx] else { continue }
                    if acc == nil { acc = Array(repeating: 0, count: v.count) }
                    guard var a = acc else { continue }
                    for j in 0..<v.count { a[j] += v[j] }
                    acc = a
                    count += 1
                }
                guard let acc, count > 0 else { return nil }
                let mean = acc.map { $0 / count }
                var sum: Float = 0
                for x in mean { sum += x * x }
                let norm = sum.squareRoot()
                guard norm > 0 else { return nil }
                let centroid = mean.map { $0 / norm }
                return EmbeddingMath.cosineSimilarity(a: current, b: centroid)
            }()

            if prevSim == nil && paraSim == nil {
                await MainActor.run { liveSemanticFeedback = nil }
                return
            }

            let feedback = LiveSemanticFeedback(
                previousSimilarity: prevSim,
                paragraphSimilarity: paraSim,
                displaySentenceIndex: sentenceIndex
            )

            await MainActor.run {
                guard isEditing else { return }
                liveSemanticFeedback = feedback
            }
        }
    }

    private func paragraphRange(containingUTF16 loc: Int, in text: NSString) -> NSRange {
        let n = text.length
        guard n > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = max(0, min(loc, n - 1))

        func isLineBreak(_ ch: unichar) -> Bool {
            ch == 0x000A || ch == 0x000D
        }

        // Paragraph boundaries are blank lines (two consecutive line breaks).
        var start = 0
        var i = clamped
        while i > 0 {
            let c0 = text.character(at: i)
            let c1 = text.character(at: i - 1)
            if isLineBreak(c0) && isLineBreak(c1) {
                start = i + 1
                break
            }
            i -= 1
        }

        var end = n
        i = clamped
        while i < n - 1 {
            let c0 = text.character(at: i)
            let c1 = text.character(at: i + 1)
            if isLineBreak(c0) && isLineBreak(c1) {
                end = i
                break
            }
            i += 1
        }

        if end < start { return NSRange(location: 0, length: n) }
        return NSRange(location: start, length: end - start)
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
        if sheetDictionaryPanelEnabled || showTokensPopover {
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
        .background(Color.appBackground)
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
                    .foregroundStyle(Color.appTextSecondary)
                    .lineLimit(2)

                if let kanaList = page.kanaList, kanaList.isEmpty == false {
                    Text(kanaList)
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            let isAnySaved = page.entries.contains { isSavedWord(for: page.matchedSurface, preferredReading: nil, entry: $0) }
            Button {
                if isAnySaved {
                    for entry in page.entries where isSavedWord(for: page.matchedSurface, preferredReading: nil, entry: entry) {
                        toggleSavedWord(surface: page.matchedSurface, preferredReading: nil, entry: entry)
                    }
                } else if let first = page.entries.first {
                    toggleSavedWord(surface: page.matchedSurface, preferredReading: nil, entry: first)
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
            // Token-aligned candidate expansion (no character-by-character growth).
            let tokens: [TextSpan] = await MainActor.run {
                furiganaSpans?.map(\.span) ?? []
            }
            let candidates = SelectionSpanResolver.candidates(selectedRange: tappedRange, tokenSpans: tokens, text: nsText)
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
                    let surface = semantic.surface
                    guard surface.isEmpty == false else { continue }
                    let lemmas = aggregatedAnnotatedSpan(for: semantic)
                        .lemmaCandidates
                        .filter { $0.isEmpty == false }
                    if lemmas.isEmpty == false {
                        out[surface] = lemmas
                    }
                }
                return out
            }

            func appendRows(_ rows: [DictionaryEntry], matchedSurface: String) async {
                // This Task is not main-actor isolated; only touch MainActor-isolated properties via MainActor.run.
                for row in rows {
                    let rowID = await MainActor.run { row.id }
                    let key = "\(matchedSurface)#\(rowID)"
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    hits.append(IncrementalLookupHit(matchedSurface: matchedSurface, entry: row))
                }
            }

            for cand in candidates {
                guard Task.isCancelled == false else { return }

                // Reduplication is structural, not semantic:
                // If the candidate covers exactly two adjacent identical tokens (after normalization),
                // prefer looking up the single token and do not treat the combined surface as a unit.
                if let startIdx = tokens.firstIndex(where: { $0.range.location == cand.range.location }), (startIdx + 1) < tokens.count {
                    let a = tokens[startIdx]
                    let b = tokens[startIdx + 1]
                    if NSMaxRange(b.range) == NSMaxRange(cand.range), NSMaxRange(a.range) == b.range.location {
                    let k0 = DictionaryKeyPolicy.lookupKey(for: a.surface)
                    let k1 = DictionaryKeyPolicy.lookupKey(for: b.surface)
                    if k0.isEmpty == false, k0 == k1 {
                        // Only apply if X exists and XX does not.
                        if let singleRows = try? await DictionarySQLiteStore.shared.lookup(term: k0, limit: 50), singleRows.isEmpty == false {
                            if let combinedRows = try? await DictionarySQLiteStore.shared.lookup(term: cand.lookupKey, limit: 1), combinedRows.isEmpty {
                                if ProcessInfo.processInfo.environment["REDUP_TRACE"] == "1" {
                                    CustomLogger.shared.info("Incremental lookup reduplication: using single token lookup for «\(a.surface)» «\(b.surface)»")
                                }
                                await appendRows(singleRows, matchedSurface: a.surface)
                                await appendRows(singleRows, matchedSurface: b.surface)
                                continue
                            }
                        }
                    }
                    }
                }

                if let rows = try? await DictionarySQLiteStore.shared.lookup(term: cand.lookupKey, limit: 50), rows.isEmpty == false {
                    await appendRows(rows, matchedSurface: cand.displayKey)
                    continue
                }

                // Deinflection hard stop: on surface miss, try deinflected lemma candidates.
                if let deinflector = try? await MainActor.run(resultType: Deinflector.self, body: {
                    try Deinflector.loadBundled(named: "deinflect")
                }) {
                    let deinflected = await MainActor.run { deinflector.deinflect(cand.displayKey, maxDepth: 8, maxResults: 32) }
                    for d in deinflected {
                        guard Task.isCancelled == false else { return }
                        if d.trace.isEmpty { continue }
                        let keys = DictionaryKeyPolicy.keys(forDisplayKey: d.baseForm)
                        guard keys.lookupKey.isEmpty == false else { continue }
                        if let rows = try? await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 50), rows.isEmpty == false {
                            if ProcessInfo.processInfo.environment["DEINFLECT_HARDSTOP_TRACE"] == "1" {
                                let trace = d.trace.map { "\($0.reason):\($0.rule.kanaIn)->\($0.rule.kanaOut)" }.joined(separator: ",")
                                CustomLogger.shared.info("Incremental lookup deinflection hard-stop: «\(cand.displayKey)» -> «\(keys.displayKey)» trace=[\(trace)]")
                            }
                            await appendRows(rows, matchedSurface: cand.displayKey)
                            break
                        }
                    }
                }

                // Lemmatization fallback: if this candidate corresponds to a Stage-2 token surface,
                // try its lemma candidates (base forms) against the dictionary.
                if let lemmas = lemmaCandidatesBySurface[cand.displayKey], lemmas.isEmpty == false {
                    for lemma in lemmas {
                        guard Task.isCancelled == false else { return }
                        let keys = DictionaryKeyPolicy.keys(forDisplayKey: lemma)
                        guard keys.lookupKey.isEmpty == false else { continue }
                        if let rows = try? await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 50), rows.isEmpty == false {
                            await appendRows(rows, matchedSurface: cand.displayKey)
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

