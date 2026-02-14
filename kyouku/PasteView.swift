import SwiftUI
import UIKit
import Foundation
import AVFoundation

struct PasteView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var words: WordsStore
    @EnvironmentObject var readingOverrides: ReadingOverridesStore
    @EnvironmentObject var tokenBoundaries: TokenBoundariesStore
    @Environment(\.undoManager) var undoManager
    @Environment(\.appColorTheme) private var appColorTheme

    @ObservedObject private var speech = SpeechManager.shared

    @State var inputText: String = ""
    @State var currentNote: Note? = nil
    @State private var noteTitleInput: String = ""
    @State private var hasManuallyEditedTitle: Bool = false
    @State private var isTitleEditAlertPresented: Bool = false
    @State private var titleEditDraft: String = ""
    @State private var hasInitialized: Bool = false
    @State var isEditing: Bool = false
    @State var furiganaAttributedText: NSAttributedString? = nil
    @State var furiganaAttributedTextBase: NSAttributedString? = nil
    @State var furiganaSpans: [AnnotatedSpan]? = nil
    @State var furiganaSemanticSpans: [SemanticSpan] = []
    @State private var furiganaRefreshToken: Int = 0
    @State private var furiganaTaskHandle: Task<Void, Never>? = nil
    @StateObject private var inlineLookup = DictionaryLookupViewModel()
    @StateObject private var selectionController = TokenSelectionController()
    @State var overrideSignature: Int = 0
    @State var customizedRanges: [NSRange] = []
    @State var showTokensPopover: Bool = false
    @State private var debugTokenListText: String = ""
    @State private var lastLoggedTokenListText: String = ""
    @State private var pendingRouterResetNoteID: UUID? = nil
    @State private var skipNextInitialFuriganaEnsure: Bool = false
    @State var isDictionarySheetPresented: Bool = false
    @State private var measuredSheetHeight: CGFloat = 0
    @State var pasteAreaFrame: CGRect? = nil

    @State private var toastText: String? = nil
    @State private var toastDismissWorkItem: DispatchWorkItem? = nil

    // Incremental lookup (tap character → lookup n, n+n1, ..., up to next newline)
    @State var incrementalPopupHits: [IncrementalLookupHit] = []
    @State var isIncrementalPopupVisible: Bool = false
    @State var incrementalLookupTask: Task<Void, Never>? = nil
    @State var savedWordOverlays: [RubyText.TokenOverlay] = []
    @State var incrementalSelectedCharacterRange: NSRange? = nil
    @State var incrementalSheetDetent: PresentationDetent = .height(420)

    @State var editorSelectedRange: NSRange? = nil

    private struct WordDefinitionsRequest: Identifiable, Hashable {
        let id = UUID()
        let surface: String
        let kana: String?
        let contextSentence: String?
        let lemmaCandidates: [String]
        let tokenPartOfSpeech: String?
        let sourceNoteID: UUID?
        let tokenParts: [WordDefinitionsView.TokenPart]
    }

    @State private var wordDefinitionsRequest: WordDefinitionsRequest? = nil

    var tokenSelection: TokenSelectionContext? {
        get { selectionController.tokenSelection }
        nonmutating set { selectionController.tokenSelection = newValue }
    }

    var persistentSelectionRange: NSRange? {
        get { selectionController.persistentSelectionRange }
        nonmutating set { selectionController.persistentSelectionRange = newValue }
    }

    var sheetSelection: TokenSelectionContext? {
        get { selectionController.sheetSelection }
        nonmutating set { selectionController.sheetSelection = newValue }
    }

    var sheetPanelHeight: CGFloat {
        get { selectionController.sheetPanelHeight }
        nonmutating set { selectionController.sheetPanelHeight = newValue }
    }

    var pendingSelectionRange: NSRange? {
        get { selectionController.pendingSelectionRange }
        nonmutating set { selectionController.pendingSelectionRange = newValue }
    }

    var pendingSplitFocusSelectionID: String? {
        get { selectionController.pendingSplitFocusSelectionID }
        nonmutating set { selectionController.pendingSplitFocusSelectionID = newValue }
    }

    var tokenPanelFrame: CGRect? {
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
    @AppStorage("readingShowFurigana") var showFurigana: Bool = true
    @AppStorage("debugPipelineTrace") private var debugPipelineTrace: Bool = false
    @AppStorage("readingWrapLines") private var wrapLines: Bool = false
    @AppStorage("readingAlternateTokenColors") private var alternateTokenColors: Bool = false
    @AppStorage("readingHighlightUnknownTokens") private var highlightUnknownTokens: Bool = false

    @AppStorage("clipboardAccessEnabled") private var clipboardAccessEnabled: Bool = true
    // One-time migration to disable token overlay highlighting that can hurt responsiveness.
    // Users can re-enable manually in the furigana options menu if desired.
    @AppStorage("paste.migrated.disableTokenOverlayHighlighting.v1") private var didDisableTokenOverlayHighlightingV1: Bool = false
    @AppStorage("readingAlternateTokenColorA") var alternateTokenColorAHex: String = "#0A84FF"
    @AppStorage("readingAlternateTokenColorB") private var alternateTokenColorBHex: String = "#FF2D55"
    @AppStorage(FuriganaKnownWordSettings.modeKey) private var knownWordFuriganaModeRaw: String = FuriganaKnownWordSettings.defaultModeRawValue
    @AppStorage(FuriganaKnownWordSettings.scoreThresholdKey) private var knownWordFuriganaScoreThreshold: Double = FuriganaKnownWordSettings.defaultScoreThreshold
    @AppStorage(FuriganaKnownWordSettings.minimumReviewsKey) private var knownWordFuriganaMinimumReviews: Int = FuriganaKnownWordSettings.defaultMinimumReviews

    @State private var showingFuriganaOptions: Bool = false
    @AppStorage("pasteViewScratchNoteID") private var scratchNoteIDRaw: String = ""
    @AppStorage("pasteViewLastOpenedNoteID") private var lastOpenedNoteIDRaw: String = ""
    @AppStorage("extractHideDuplicateTokens") private var hideDuplicateTokens: Bool = false
    @AppStorage("extractHideCommonParticles") private var hideCommonParticles: Bool = false
    @AppStorage("extractPropagateTokenEdits") var propagateTokenEdits: Bool = false
    @AppStorage(CommonParticleSettings.storageKey) private var commonParticlesRaw: String = CommonParticleSettings.defaultRawValue
    @AppStorage("debugDisableDictionaryPopup") private var debugDisableDictionaryPopup: Bool = false
    @AppStorage("debugHighlightAllDictionaryEntries") private var debugHighlightAllDictionaryEntries: Bool = false
    @AppStorage("debugTokenGeometryOverlay") private var debugTokenGeometryOverlay: Bool = false
    @AppStorage("debugPasteDragToMoveWords") private var debugPasteDragToMoveWords: Bool = false

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

    
    static let coordinateSpaceName = "PasteViewRootSpace"
    @State private var pinchZoomInProgress: Bool = false
    @State private var pinchZoomBaselineTextSize: Double? = nil
    @State private var pinchZoomBaselineFuriganaSize: Double? = nil
    @State private var pendingFuriganaSizeRefreshTask: Task<Void, Never>? = nil

    private static let readingSizeRange: ClosedRange<Double> = 1...30
    private static let pinchRefreshDebounceNanoseconds: UInt64 = 140_000_000

    private func clampReadingSize(_ value: Double) -> Double {
        min(max(value, Self.readingSizeRange.lowerBound), Self.readingSizeRange.upperBound)
    }

    private func snapReadingSize(_ value: Double, step: Double = 0.5) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func scheduleFuriganaSizeRefresh(reason: String) {
        pendingFuriganaSizeRefreshTask?.cancel()
        pendingFuriganaSizeRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: Self.pinchRefreshDebounceNanoseconds)
            } catch {
                return
            }
            guard Task.isCancelled == false else { return }
            triggerFuriganaRefreshIfNeeded(reason: reason, recomputeSpans: false)
        }
    }

    private var pinchToZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchZoomInProgress == false {
                    pinchZoomInProgress = true
                    pinchZoomBaselineTextSize = readingTextSize
                    pinchZoomBaselineFuriganaSize = readingFuriganaSize
                }
                guard let baseText = pinchZoomBaselineTextSize,
                      let baseFurigana = pinchZoomBaselineFuriganaSize else { return }

                let factor = Double(scale)
                let nextText = snapReadingSize(clampReadingSize(baseText * factor))
                let nextFurigana = snapReadingSize(clampReadingSize(baseFurigana * factor))

                if abs(nextText - readingTextSize) > .ulpOfOne {
                    readingTextSize = nextText
                }
                if abs(nextFurigana - readingFuriganaSize) > .ulpOfOne {
                    readingFuriganaSize = nextFurigana
                }
            }
            .onEnded { _ in
                pinchZoomInProgress = false
                pinchZoomBaselineTextSize = nil
                pinchZoomBaselineFuriganaSize = nil
                pendingFuriganaSizeRefreshTask?.cancel()
                pendingFuriganaSizeRefreshTask = nil
                triggerFuriganaRefreshIfNeeded(reason: "pinch zoom ended", recomputeSpans: false)
            }
    }
    private static let inlineDictionaryPanelEnabledFlag = true
    private static let dictionaryPopupEnabledFlag = true // Tap in paste area shows popup + highlight.
    private static let dictionaryPopupLoggingEnabledFlag = false
    private static let incrementalLookupEnabledFlag = false
    private static let sheetMaxHeightFraction: CGFloat = 0.8
    private static let sheetExtraPadding: CGFloat = 36
    private let furiganaPipeline = FuriganaPipelineService()
    var incrementalLookupEnabled: Bool { Self.incrementalLookupEnabledFlag }
    private var dictionaryPopupEnabled: Bool { Self.dictionaryPopupEnabledFlag && incrementalLookupEnabled == false && debugDisableDictionaryPopup == false }
    private var dictionaryPopupLoggingEnabled: Bool { Self.dictionaryPopupLoggingEnabledFlag }
    private var inlineDictionaryPanelEnabled: Bool { Self.inlineDictionaryPanelEnabledFlag && dictionaryPopupEnabled }
    var sheetDictionaryPanelEnabled: Bool { dictionaryPopupEnabled && inlineDictionaryPanelEnabled == false }
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
    var tokenHighlightsEnabled: Bool {
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

    private func emitTokenListLog(_ message: String) {
        CustomLogger.shared.print(message)
        NSLog("%@", message)
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
        .onChange(of: debugPipelineTrace) { _, enabled in
            guard enabled else { return }
            guard debugTokenListText.isEmpty == false else {
                emitTokenListLog("[TokenList] (no cached token list yet)")
                return
            }
            emitTokenListLog("[TokenList]\n\(debugTokenListText)")
            lastLoggedTokenListText = debugTokenListText
        }
        .onChange(of: debugHighlightAllDictionaryEntries) { _, _ in
            // Ensure toggling the setting immediately updates the rendered text.
            triggerFuriganaRefreshIfNeeded(reason: "debug highlight all dictionary entries toggled", recomputeSpans: false)
        }
        .sheet(item: $wordDefinitionsRequest, onDismiss: {
            // When the dictionary details sheet is dismissed, also clear the
            // token selection in the paste area so the highlight goes away.
            clearSelection(resetPersistent: true)
        }) { request in
            NavigationStack {
                WordDefinitionsView(
                    surface: request.surface,
                    kana: request.kana,
                    contextSentence: request.contextSentence,
                    lemmaCandidates: request.lemmaCandidates,
                    tokenPartOfSpeech: request.tokenPartOfSpeech,
                    sourceNoteID: request.sourceNoteID,
                    tokenParts: request.tokenParts
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
            .toolbar {
                coreToolbar
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        SpeechManager.shared.togglePlayPause(
                            sessionID: noteSpeechSessionID,
                            text: inputText,
                            language: "ja-JP"
                        )
                    } label: {
                        Image(systemName: noteSpeechIsPlaying ? "pause.circle" : "play.circle")
                    }
                    .accessibilityLabel(noteSpeechIsPlaying ? "Pause reading" : (noteSpeechIsPaused ? "Resume reading" : "Read note"))
                    .accessibilityHint("Speaks the entire note")
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .contextMenu {
                        Menu {
                            Button {
                                SpeechManager.shared.adjustRate(by: -0.05)
                                showToast("Rate: \(SpeechManager.formatRate(SpeechManager.shared.preferredRate))")
                            } label: {
                                Label("Slower", systemImage: "tortoise")
                            }
                            Button {
                                SpeechManager.shared.adjustRate(by: 0.05)
                                showToast("Rate: \(SpeechManager.formatRate(SpeechManager.shared.preferredRate))")
                            } label: {
                                Label("Faster", systemImage: "hare")
                            }
                            Button {
                                SpeechManager.shared.preferredRate = AVSpeechUtteranceDefaultSpeechRate
                                showToast("Rate reset")
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Label("Rate", systemImage: "speedometer")
                        }

                        Menu {
                            Button {
                                SpeechManager.shared.adjustPitch(by: -0.1)
                                showToast("Pitch: \(SpeechManager.formatPitch(SpeechManager.shared.preferredPitch))")
                            } label: {
                                Label("Lower", systemImage: "arrow.down")
                            }
                            Button {
                                SpeechManager.shared.adjustPitch(by: 0.1)
                                showToast("Pitch: \(SpeechManager.formatPitch(SpeechManager.shared.preferredPitch))")
                            } label: {
                                Label("Higher", systemImage: "arrow.up")
                            }
                            Button {
                                SpeechManager.shared.preferredPitch = 1.0
                                showToast("Pitch reset")
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Label("Pitch", systemImage: "waveform")
                        }

                        Menu {
                            Button {
                                SpeechManager.shared.setPreferredVoiceIdentifier(nil)
                                showToast("Voice: Japanese default")
                            } label: {
                                Label("Japanese default", systemImage: "person.crop.circle")
                            }

                            let voices = SpeechManager.shared.availableVoices(language: "ja-JP")
                            if voices.isEmpty {
                                Text("No Japanese voices")
                            } else {
                                ForEach(voices) { v in
                                    Button {
                                        SpeechManager.shared.setPreferredVoiceIdentifier(v.identifier)
                                        showToast("Voice: \(v.name)")
                                    } label: {
                                        if SpeechManager.shared.preferredVoiceIdentifier == v.identifier {
                                            Label(v.name, systemImage: "checkmark")
                                        } else {
                                            Text(v.name)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Voice", systemImage: "speaker.wave.2")
                        }

                        Button {
                            SpeechManager.shared.resetSpeechIndicator(sessionID: noteSpeechSessionID)
                            showToast("Speech indicator reset")
                        } label: {
                            Label("Reset indicator", systemImage: "sparkles")
                        }
                        Button(role: .destructive) {
                            SpeechManager.shared.stop(sessionID: noteSpeechSessionID)
                        } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                    }
                }
            }
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
                SpeechManager.shared.stop(sessionID: noteSpeechSessionID)
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
            .onChange(of: isEditing) { oldValue, editing in
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
            .onChange(of: alternateTokenColors) { oldValue, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "alternate token colors toggled on" : "alternate token colors toggled off",
                    recomputeSpans: false
                )
                showToast(enabled ? "Alternate token colors enabled" : "Alternate token colors disabled")
            }
            .onChange(of: highlightUnknownTokens) { oldValue, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "unknown highlight toggled on" : "unknown highlight toggled off",
                    recomputeSpans: false
                )
                showToast(enabled ? "Highlight unknown words enabled" : "Highlight unknown words disabled")
            }
            .onChange(of: readingFuriganaSize) {
                guard showFurigana else { return }
                if pinchZoomInProgress {
                    scheduleFuriganaSizeRefresh(reason: "furigana font size changed (pinch)")
                } else {
                    triggerFuriganaRefreshIfNeeded(reason: "furigana font size changed", recomputeSpans: false)
                }
            }
            .onChange(of: readingHeadwordSpacingPadding) { _, enabled in
                triggerFuriganaRefreshIfNeeded(
                    reason: enabled ? "headword spacing padding toggled on" : "headword spacing padding toggled off",
                    recomputeSpans: false,
                    skipTailSemanticMerge: true
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
                handleSelectionLookup()

                let knownWordMode = FuriganaKnownWordMode(rawValue: knownWordFuriganaModeRaw) ?? .off
                if showFurigana, knownWordMode != .off {
                    // Known-word suppression runs during Stage 3 ruby projection.
                    // Rebuild attributed text when selection changes so the active token can be
                    // exempted from suppression and remains readable while focused.
                    triggerFuriganaRefreshIfNeeded(
                        reason: "selection changed for known-word ruby suppression",
                        recomputeSpans: false
                    )
                }
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
            .overlay(alignment: Alignment.bottom) {
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

    

    private var editorColumn: some View {
        // Precompute helpers outside of the ViewBuilder to avoid non-View statements inside VStack
        let speechOverlay = noteSpeechOverlay(for: inputText)
        let extraOverlays: [RubyText.TokenOverlay] = {
            var overlays: [RubyText.TokenOverlay] = incrementalLookupEnabled ? savedWordOverlays : []
            if let speechOverlay {
                overlays.append(speechOverlay)
            }
            return overlays
        }()

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

        let interTokenSpacing: [Int: CGFloat] = {
            guard let noteID = currentNote?.id else { return [:] }
            return tokenBoundaries.interTokenSpacing(for: noteID, text: inputText)
        }()

        let tokenSpacingValueProvider: ((Int) -> CGFloat)? = debugPasteDragToMoveWords ? {
            guard let noteID = currentNote?.id else { return 0 }
            return tokenBoundaries.interTokenSpacingWidth(noteID: noteID, boundaryUTF16Index: $0)
        } : nil

        let onTokenSpacingChanged: ((Int, CGFloat, Bool) -> Void)? = debugPasteDragToMoveWords ? { boundary, width, _ in
            guard let noteID = currentNote?.id else { return }
            tokenBoundaries.setInterTokenSpacing(noteID: noteID, boundaryUTF16Index: boundary, width: width, text: inputText)
            // Spacing is display-only; no need to resync notes or spans.
        } : nil

        return PasteEditorColumnBody(
            text: $inputText,
            editorSelectedRange: $editorSelectedRange,
            furiganaText: furiganaAttributedText,
            furiganaSpans: furiganaSpans,
            semanticSpans: furiganaSemanticSpans,
            textSize: readingTextSize,
            isEditing: $isEditing,
            showFurigana: $showFurigana,
            wrapLines: $wrapLines,
            alternateTokenColors: $alternateTokenColors,
            highlightUnknownTokens: $highlightUnknownTokens,
            padHeadwordSpacing: $readingHeadwordSpacingPadding,
            incrementalLookupEnabled: incrementalLookupEnabled,
            lineSpacing: readingLineSpacing,
            globalKerningPixels: readingGlobalKerningPixels,
            tokenPalette: alternateTokenPalette,
            unknownTokenColor: unknownTokenColor,
            selectedRangeHighlight: incrementalLookupEnabled ? incrementalSelectedCharacterRange : persistentSelectionRange,
            scrollToSelectedRangeToken: 0,
            customizedRanges: customizedRanges,
            extraTokenOverlays: extraOverlays,
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

                // Also emit token list text to logs for debugging.
                // Keep it behind the in-app toggle; log even if the string hasn't changed
                // (toggling tracing on shouldn't require a layout/text change to re-emit).
                if debugPipelineTrace, text != lastLoggedTokenListText {
                    emitTokenListLog("[TokenList]\n\(text)")
                    lastLoggedTokenListText = text
                }
            },
            coordinateSpaceName: Self.coordinateSpaceName,
            interTokenSpacing: interTokenSpacing,
            tokenSpacingValueProvider: tokenSpacingValueProvider,
            onTokenSpacingChanged: onTokenSpacingChanged,
            onHideKeyboard: {
                hideKeyboard()
            },
            onPaste: {
                pasteFromClipboard()
            },
            onSave: {
                saveNote()
            },
            onPasteContextMenuAction: { action in
                handlePasteContextMenuAction(action)
            },
            clipboardAccessEnabled: clipboardAccessEnabled,
            onToggleFurigana: { enabled in
                if enabled {
                    // Manual toggle should not force a fresh segmentation pass; reuse
                    // existing spans and just rebuild the ruby text.
                    triggerFuriganaRefreshIfNeeded(reason: "manual toggle button", recomputeSpans: false)
                }
            },
            onShowToast: { message in
                showToast(message)
            },
            onHaptic: {
                fireContextMenuHaptic()
            }
        )
        .simultaneousGesture(pinchToZoomGesture)
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

    @MainActor
    private func processPendingRouterResetRequest() {
        guard let resetID = pendingRouterResetNoteID else { return }
        guard let currentID = currentNote?.id, currentID == resetID else { return }

        pendingRouterResetNoteID = nil
        router.pendingResetNoteID = nil

        readingOverrides.removeAll(for: resetID)
        tokenBoundaries.removeAll(for: resetID)

        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        triggerFuriganaRefreshIfNeeded(reason: "reset custom spans", recomputeSpans: true)
        showToast("Reset custom spans")
    }

    private func ensureClipboardAccessEnabledOrToast() -> Bool {
        guard clipboardAccessEnabled else {
            showToast("Clipboard access is disabled in Settings")
            return false
        }
        return true
    }

    private func sendStandardEditAction(_ selector: Selector) {
        // Best-effort: enable editing so the text view can accept responder actions.
        setEditing(true)
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(selector, to: nil, from: nil, for: nil)
        }
    }

    private func handlePasteContextMenuAction(_ action: PasteControlsBar.PasteContextMenuAction) {
        switch action {
        case .cut:
            guard ensureClipboardAccessEnabledOrToast() else { return }
            sendStandardEditAction(#selector(UIResponderStandardEditActions.cut(_:)))
        case .copy:
            guard ensureClipboardAccessEnabledOrToast() else { return }
            sendStandardEditAction(#selector(UIResponderStandardEditActions.copy(_:)))
        case .pasteInsert:
            guard ensureClipboardAccessEnabledOrToast() else { return }
            sendStandardEditAction(#selector(UIResponderStandardEditActions.paste(_:)))
        case .pasteReplaceAll:
            pasteFromClipboard()
        case .selectAll:
            sendStandardEditAction(#selector(UIResponderStandardEditActions.selectAll(_:)))
        case .newNoteFromClipboard:
            newNoteFromClipboard()
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
        PasteCoreToolbar(
            isTitleEditPresented: $isTitleEditAlertPresented,
            titleEditDraft: $titleEditDraft,
            navigationTitleText: navigationTitleText,
            onResetSpans: {
                resetAllCustomSpans()
            },
            showTokensSheet: $showTokensPopover,
            tokenListSheet: {
                PasteTokenListSheet(
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
        )
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

    

    @ViewBuilder
    private var incrementalLookupOverlay: some View { EmptyView() }

    private var incrementalSheetDetents: Set<PresentationDetent> {
        Set([.height(300), .height(420), .height(560), .large])
    }

    var incrementalPreferredSheetDetent: PresentationDetent {
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
        let preferred = normalizedReading(preferredReadingForSelection(selection))

        return PasteInlineTokenActionPanel(
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
            overrideSignature: overrideSignature,
            focusSplitMenu: pendingSplitFocusSelectionID == selection.id,
            onSplitFocusConsumed: { pendingSplitFocusSelectionID = nil },
            coordinateSpaceName: Self.coordinateSpaceName
        )
    }

    private func pasteFromClipboard() {
        guard ensureClipboardAccessEnabledOrToast() else { return }
        if let str = UIPasteboard.general.string {
            inputText = str
        } else {
            showToast("Clipboard is empty")
        }
    }

    private func newNoteFromClipboard() {
        guard ensureClipboardAccessEnabledOrToast() else { return }
        guard let str = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), str.isEmpty == false else {
            showToast("Clipboard is empty")
            return
        }

        let resolvedTitle = inferredTitle(from: str)
        notes.addNote(title: resolvedTitle, text: str)
        if let newest = notes.notes.first {
            router.noteToOpen = newest
            router.pasteShouldBeginEditing = true
            router.selectedTab = .paste
        }
        PasteBufferStore.save(str)
        showToast("Pasted to new note")
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
        TitleEditModalView(
            isPresented: $isTitleEditAlertPresented,
            draft: $titleEditDraft,
            onApply: {
                applyTitleEditDraft()
            }
        )
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

    var activeNoteID: UUID {
        currentNote?.id ?? scratchNoteID
    }

    private var noteSpeechSessionID: String {
        "paste-note:\(activeNoteID.uuidString)"
    }

    private var isNoteSpeechActive: Bool {
        speech.activeSessionID == noteSpeechSessionID
    }

    private var noteSpeechIsPlaying: Bool {
        isNoteSpeechActive && speech.isSpeaking && speech.isPaused == false
    }

    private var noteSpeechIsPaused: Bool {
        isNoteSpeechActive && speech.isSpeaking && speech.isPaused
    }

    private func noteSpeechOverlay(for text: String) -> RubyText.TokenOverlay? {
        guard isNoteSpeechActive else { return nil }
        guard let range = speech.currentSpokenRange else { return nil }
        return tokenOverlay(for: text, range: range)
    }

    private func tokenOverlay(for text: String, range: NSRange) -> RubyText.TokenOverlay? {
        let ns = text as NSString
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard NSMaxRange(range) <= ns.length else { return nil }
        let snippet = ns.substring(with: range)
        guard snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }

        // `TokenOverlay` maps to `.foregroundColor` (not background highlight),
        // so choose a high-contrast color that stays readable in dark mode.
        let color = UIColor.systemOrange
        return RubyText.TokenOverlay(range: range, color: color)
    }

    func clearSelection(resetPersistent: Bool = true) {
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

        // Use semantic spans (post Stage 2.5 + tail merge) as the token basis for
        // dictionary candidate generation. This makes late-stage token combining
        // visible to lookup behavior without requiring user-authored base spans.
        let tokens: [TextSpan] = {
            if furiganaSemanticSpans.isEmpty == false {
                return furiganaSemanticSpans.map { TextSpan(range: $0.range, surface: $0.surface, isLexiconMatch: false) }
            }
            return furiganaSpans?.map(\.span) ?? []
        }()
        let selectedRange = selection.range
        let currentText = inputText
        let selectionID = selection.id

        // If a semantic token is a merge of multiple Stage-1 spans, the merged surface may not exist
        // as a dictionary headword even when some components do. Keep determinism (single transaction),
        // but add bounded component/n-gram fallbacks so the popup doesn't dead-end on a made-up composite.
        let lemmaFallbacks: [String] = {
            func normalized(_ raw: String) -> String {
                raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var out: [String] = []
            out.reserveCapacity(16)
            var seen: Set<String> = []

            func appendUnique(_ raw: String) {
                let trimmed = normalized(raw)
                guard trimmed.isEmpty == false else { return }
                if seen.insert(trimmed).inserted {
                    out.append(trimmed)
                }
            }

            // 1) Aggregated MeCab lemma candidates (existing behavior).
            for lemma in selection.annotatedSpan.lemmaCandidates {
                appendUnique(lemma)
            }

            // 2) If this selection covers multiple Stage-1 spans, also try component surfaces and
            //    short adjacent concatenations (e.g. A, B, AB, BC, ABC) as fallbacks.
            if selection.sourceSpanIndices.count > 1, let stage1 = furiganaSpans {
                let idx = selection.sourceSpanIndices
                if idx.lowerBound >= 0, idx.upperBound <= stage1.count {
                    let group = Array(stage1[idx.lowerBound..<idx.upperBound])
                    let surfaces = group.map { normalized($0.span.surface) }.filter { $0.isEmpty == false }

                    for s in surfaces {
                        appendUnique(s)
                    }

                    // Bounded n-grams: keep small to avoid doing too many dictionary queries.
                    let maxGram = min(4, surfaces.count)
                    if surfaces.count >= 2 {
                        for i in 0..<surfaces.count {
                            var combined = ""
                            for len in 2...maxGram {
                                let j = i + len
                                if j > surfaces.count { break }
                                if combined.isEmpty {
                                    combined = surfaces[i..<j].joined(separator: "")
                                } else {
                                    combined += surfaces[j - 1]
                                }
                                appendUnique(combined)
                            }
                        }
                    }

                    // Include any per-span lemma candidates that might not have been surfaced by aggregation.
                    for span in group {
                        for lemma in span.lemmaCandidates {
                            appendUnique(lemma)
                        }
                    }
                }
            }

            return out
        }()

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

    func isSavedWord(for surface: String, preferredReading: String?, entry: DictionaryEntry) -> Bool {
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
            guard word.isAssociated(with: noteID) else { return false }
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

    func toggleSavedWord(surface: String, preferredReading: String?, entry: DictionaryEntry) {
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
            guard word.isAssociated(with: noteID) else { return false }
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
            if let noteID {
                words.removeWords(ids: matchingIDs, fromNoteID: noteID)
            } else {
                words.delete(ids: matchingIDs)
            }
        }
    }

    private func presentWordDefinitions(for selection: TokenSelectionContext) {
        wordDefinitionsRequest = WordDefinitionsRequest(
            surface: selection.surface,
            kana: normalizedReading(preferredReadingForSelection(selection)),
            contextSentence: SentenceContextExtractor.sentence(containing: selection.range, in: inputText)?.sentence,
            lemmaCandidates: selection.annotatedSpan.lemmaCandidates,
            tokenPartOfSpeech: selection.annotatedSpan.partOfSpeech,
            sourceNoteID: currentNote?.id,
            tokenParts: tokenPartsForSelection(selection)
        )
    }

    private func tokenPartsForSelection(_ selection: TokenSelectionContext) -> [WordDefinitionsView.TokenPart] {
        let indices = selection.sourceSpanIndices
        guard indices.isEmpty == false else { return [] }
        guard let stage1 = furiganaSpans, stage1.isEmpty == false else { return [] }

        var parts: [WordDefinitionsView.TokenPart] = []
        parts.reserveCapacity(min(8, indices.count))
        var seen: Set<String> = []

        for idx in indices {
            guard stage1.indices.contains(idx) else { continue }
            let annotated = stage1[idx]
            guard let trimmed = trimmedRangeAndSurface(for: annotated.span.range) else { continue }
            guard isHardBoundaryOnly(trimmed.surface) == false else { continue }

            let reading = normalizedReading(preferredReading(for: trimmed.range, fallback: annotated.readingKana))
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

    

    func trimmedRangeAndSurface(for spanRange: NSRange) -> (range: NSRange, surface: String)? {
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

    func aggregatedAnnotatedSpan(for semantic: SemanticSpan) -> AnnotatedSpan {
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

    func presentDictionaryForSpan(at index: Int, focusSplitMenu: Bool) {
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
            guard word.isAssociated(with: noteID) else { return false }
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
                if let noteID {
                    words.removeWords(ids: ids, fromNoteID: noteID)
                } else {
                    words.delete(ids: ids)
                }
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

    func isKanaOnlySurface(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            if isKanaScalar(scalar) { return true }
            // Half-width katakana block.
            if (0xFF66...0xFF9F).contains(scalar.value) { return true }
            return false
        }
    }

    func normalizedReading(_ reading: String?) -> String? {
        guard let value = reading?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else { return nil }
        return value
    }

    func kanaFoldToHiragana(_ value: String) -> String {
        // Fold katakana/hiragana differences so "カタカナ" and "かたかな" compare equal.
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    func kanaFoldToHiragana(_ value: String?) -> String? {
        guard let value else { return nil }
        return kanaFoldToHiragana(value)
    }

    func kanaVariants(_ value: String) -> [String] {
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

    func trailingKanaSuffix(in surface: String) -> String? {
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

    private func ensureInitialFuriganaReady(reason: String) {
        if skipNextInitialFuriganaEnsure {
            return
        }
        guard furiganaSpans == nil || furiganaAttributedText == nil else { return }
        guard inputText.isEmpty == false else { return }
        triggerFuriganaRefreshIfNeeded(reason: reason, recomputeSpans: true)
    }

    func triggerFuriganaRefreshIfNeeded(
        reason: String = "state change",
        recomputeSpans: Bool = true,
        skipTailSemanticMerge: Bool = false
    ) {
        guard inputText.isEmpty == false else { return }
        furiganaRefreshToken &+= 1
        startFuriganaTask(token: furiganaRefreshToken, recomputeSpans: recomputeSpans, skipTailSemanticMerge: skipTailSemanticMerge)
    }

    private func assignInputTextFromExternalSource(_ text: String) {
        guard inputText != text else { return }
        skipNextInitialFuriganaEnsure = true
        inputText = text
    }

    private func startFuriganaTask(token: Int, recomputeSpans: Bool, skipTailSemanticMerge: Bool) {
        guard let taskBody = makeFuriganaTask(token: token, recomputeSpans: recomputeSpans, skipTailSemanticMerge: skipTailSemanticMerge) else { return }
        furiganaTaskHandle?.cancel()
        furiganaTaskHandle = Task {
            await taskBody()
        }
    }

    private func makeFuriganaTask(token: Int, recomputeSpans: Bool, skipTailSemanticMerge: Bool) -> (() async -> Void)? {
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
            skipTailSemanticMerge: skipTailSemanticMerge,
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
                    furiganaAttributedText = base
                } else if showFurigana == false {
                    let base = NSAttributedString(string: currentText)
                    furiganaAttributedTextBase = base
                    furiganaAttributedText = base
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
                    {
                        if let noteID {
                            return words.words.filter { $0.sourceNoteIDs.contains(noteID) }
                        }
                        return words.words
                    }()
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
