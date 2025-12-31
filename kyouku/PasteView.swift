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
    @StateObject private var selectionController = TokenSelectionController()
    @State private var overrideSignature: Int = 0
    @State private var customizedRanges: [NSRange] = []
    @State private var showTokensPopover: Bool = false
    @State private var showAdjustedSpansPopover: Bool = false
    @State private var pendingRouterResetNoteID: UUID? = nil
    @State private var skipNextInitialFuriganaEnsure: Bool = false
    @State private var isDictionarySheetPresented: Bool = false
    @State private var measuredSheetHeight: CGFloat = 0

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

    private static let furiganaLogger = DiagnosticsLogging.logger(.furigana)
    private static let selectionLogger = DiagnosticsLogging.logger(.pasteSelection)
    private static let coordinateSpaceName = "PasteViewRootSpace"
    private static let inlineDictionaryPanelEnabledFlag = false
    private static let dictionaryPopupEnabledFlag = true // Temporary debug switch so highlight behavior can be isolated without showing the popup.
    private static let sheetMaxHeightFraction: CGFloat = 0.8
    private static let sheetExtraPadding: CGFloat = 36
    private let furiganaPipeline = FuriganaPipelineService()
    private var dictionaryPopupEnabled: Bool { Self.dictionaryPopupEnabledFlag }
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
    private var tokenHighlightsEnabled: Bool { alternateTokenColors || highlightUnknownTokens }
    private var sheetSelectionBinding: Binding<TokenSelectionContext?> {
        Binding(
            get: { showTokensPopover ? nil : sheetSelection },
            set: { sheetSelection = $0 }
        )
    }
    private var commonParticleSet: Set<String> {
        Set(CommonParticleSettings.decodeList(from: commonParticlesRaw))
    }
    
    private var preferredOverscrollPadding: CGFloat {
        guard isDictionarySheetPresented else { return 0 }
        let screenHeight: CGFloat = {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                return scene.screen.bounds.height
            }
            return 480
        }()
        let halfScreen = screenHeight * 0.5
        let measured = max(0, measuredSheetHeight + 50) // add some breathing room
        let basePadding = max(measured, halfScreen)
        return basePadding * 0.75
    }

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
        } else {
            coreContent
        }
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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var resetSpansButton: some View {
        Button {
            // Intentionally reuse the global reset path shared with NotesView to keep behavior consistent.
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
            .frame(minWidth: 320, idealWidth: 420, maxWidth: 520, minHeight: 220, idealHeight: 320, maxHeight: 520)
        }
    }

    private var adjustedSpansDebugText: String {
        guard let spans = furiganaSpans, spans.isEmpty == false else {
            return "(No spans yet)"
        }
        return SegmentationService.describe(spans: spans.map(\.span))
    }

    private var coreContent: some View {
        ZStack(alignment: .bottom) {
            editorColumn
            inlineDictionaryOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(noteTitleInput.isEmpty ? "Paste" : noteTitleInput)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                adjustedSpansButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    resetSpansButton
                    tokenListButton
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionController.tokenSelection == nil {
                Color.clear.frame(height: 24)
            }
        }
        .onAppear { onAppearHandler() }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
            furiganaTaskHandle?.cancel()
        }
        .onChange(of: inputText) { _, newValue in
            skipNextInitialFuriganaEnsure = false
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
                triggerFuriganaRefreshIfNeeded(reason: "editing toggled on", recomputeSpans: true)
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
                triggerFuriganaRefreshIfNeeded(reason: "show furigana toggled on", recomputeSpans: true)
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
        .onChange(of: selectionController.tokenSelection) { oldSelection, newSelection in
            if newSelection == nil {
                if isDictionarySheetPresented {
                    isDictionarySheetPresented = false
                }
            }
            if dictionaryPopupEnabled {
                switch (oldSelection, newSelection) {
                case (nil, .some(let newCtx)):
                    let r = newCtx.range
                    Self.selectionLogger.debug("Dictionary popup shown (selection change) spanIndex=\(newCtx.spanIndex) range=\(r.location)-\(NSMaxRange(r)) surface=\(newCtx.surface, privacy: .public) inline=\(self.inlineDictionaryPanelEnabled) sheet=\(self.sheetDictionaryPanelEnabled)")
                case (.some(_), nil):
                    Self.selectionLogger.debug("Dictionary popup hidden (selection cleared)")
                case (.some(let oldCtx), .some(let newCtx)):
                    if oldCtx.id != newCtx.id {
                        let oldR = oldCtx.range
                        let newR = newCtx.range
                        Self.selectionLogger.debug("Dictionary popup replaced oldSpanIndex=\(oldCtx.spanIndex) oldRange=\(oldR.location)-\(NSMaxRange(oldR)) -> newSpanIndex=\(newCtx.spanIndex) newRange=\(newR.location)-\(NSMaxRange(newR)) surface=\(newCtx.surface, privacy: .public)")
                    } else if oldCtx.range.location != newCtx.range.location || oldCtx.range.length != newCtx.range.length || oldCtx.surface != newCtx.surface {
                        let newR = newCtx.range
                        Self.selectionLogger.debug("Dictionary popup updated spanIndex=\(newCtx.spanIndex) range=\(newR.location)-\(NSMaxRange(newR)) surface=\(newCtx.surface, privacy: .public)")
                    }
                default:
                    break
                }
            }
            handleSelectionLookup(for: newSelection?.surface ?? "")
        }
        .onChange(of: sheetSelection?.id) { oldID, newID in
            guard dictionaryPopupEnabled else { return }
            if oldID == nil, let _ = newID {
                if let ctx = sheetSelection {
                    let r = ctx.range
                    Self.selectionLogger.debug("Dictionary popup shown (sheet binding) spanIndex=\(ctx.spanIndex) range=\(r.location)-\(NSMaxRange(r)) surface=\(ctx.surface, privacy: .public)")
                } else {
                    Self.selectionLogger.debug("Dictionary popup shown (sheet binding)")
                }
            } else if let _ = oldID, newID == nil {
                Self.selectionLogger.debug("Dictionary popup hidden (sheet binding cleared)")
            } else if let _ = oldID, let _ = newID, let ctx = sheetSelection {
                let r = ctx.range
                Self.selectionLogger.debug("Dictionary popup replaced (sheet binding) range=\(r.location)-\(NSMaxRange(r)) surface=\(ctx.surface, privacy: .public)")
            }
        }
        .onChange(of: currentNote?.id) { _, newValue in
            lastOpenedNoteIDRaw = newValue?.uuidString ?? ""
            clearSelection()
            overrideSignature = computeOverrideSignature()
            updateCustomizedRanges()
            processPendingRouterResetRequest()
        }
        .onReceive(readingOverrides.$overrides) { _ in
            handleOverridesExternalChange()
        }
        .onChange(of: router.pendingResetNoteID) { _, newValue in
            pendingRouterResetNoteID = newValue
            processPendingRouterResetRequest()
        }
        .onChange(of: tokenSelection == nil) { _, isNil in
            if isNil {
                tokenPanelFrame = nil
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isDictionarySheetPresented {
                isDictionarySheetPresented = false
                clearSelection(resetPersistent: true)
            }
        }
    }

    @ViewBuilder
    private var tokenListSheet: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 16) {
                    tokenFilterControls
                    Divider()
                    TokenListPanel(
                        items: tokenListItems,
                        isReady: furiganaSpans != nil,
                        isEditing: isEditing,
                        selectedRange: persistentSelectionRange,
                        onSelect: { presentDictionaryForSpan(at: $0, focusSplitMenu: false) },
                        onGoTo: { goToSpanInNote(at: $0) },
                        onAdd: { bookmarkToken(at: $0) },
                        onMergeLeft: { mergeSpan(at: $0, direction: .previous) },
                        onMergeRight: { mergeSpan(at: $0, direction: .next) },
                        onSplit: { startSplitFlow(for: $0) },
                        canMergeLeft: { canMergeSpan(at: $0, direction: .previous) },
                        canMergeRight: { canMergeSpan(at: $0, direction: .next) }
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if sheetDictionaryPanelEnabled, let selection = sheetSelection {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.25)
                            .ignoresSafeArea()
                            .transition(.opacity)
                            .onTapGesture { clearSelection(resetPersistent: false) }

                        dictionaryPanel(for: selection, enableDragToDismiss: true, embedInMaterialBackground: true)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .zIndex(1)
                }
            }
            .navigationTitle("Extract Words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showTokensPopover = false }
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: sheetSelection?.id)
        }
    }

    private var tokenFilterControls: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("Hide duplicates", isOn: $hideDuplicateTokens)
            Toggle("Hide particles", isOn: $hideCommonParticles)
        }
        .toggleStyle(.switch)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            FuriganaRenderingHost(
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
                enableTapInspection: true,
                bottomOverscrollPadding: preferredOverscrollPadding,
                onSpanSelection: handleInlineSpanSelection,
                contextMenuStateProvider: { inlineContextMenuState },
                onContextMenuAction: handleContextMenuAction
            )
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            editorToolbar
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

    private var tokenInspectorPanel: some View {
        TokenListPanel(
            items: tokenListItems,
            isReady: furiganaSpans != nil,
            isEditing: isEditing,
            selectedRange: persistentSelectionRange,
            onSelect: { presentDictionaryForSpan(at: $0, focusSplitMenu: false) },
            onGoTo: { goToSpanInNote(at: $0) },
            onAdd: { bookmarkToken(at: $0) },
            onMergeLeft: { mergeSpan(at: $0, direction: .previous) },
            onMergeRight: { mergeSpan(at: $0, direction: .next) },
            onSplit: { startSplitFlow(for: $0) },
            canMergeLeft: { canMergeSpan(at: $0, direction: .previous) },
            canMergeRight: { canMergeSpan(at: $0, direction: .next) }
        )
        .padding(.top, 12)
    }

    private var tokenListItems: [TokenListItem] {
        guard let spans = furiganaSpans else { return [] }
        var seenKeys: Set<String> = []
        let particleSet: Set<String> = hideCommonParticles ? commonParticleSet : []

        return spans.enumerated().compactMap { index, span in
            guard let trimmed = trimmedRangeAndSurface(for: span.span.range) else { return nil }
            let normalizedSurface = trimmed.surface.trimmingCharacters(in: .whitespacesAndNewlines)

            if hideCommonParticles, particleSet.contains(normalizedSurface) {
                return nil
            }

            let reading = normalizedReading(span.readingKana)
            let displayReading = readingWithOkurigana(surface: trimmed.surface, baseReading: reading)
            if hideDuplicateTokens {
                let key = tokenDuplicateKey(surface: normalizedSurface, reading: reading)
                if seenKeys.contains(key) {
                    return nil
                }
                seenKeys.insert(key)
            }

            let alreadySaved = hasSavedWord(surface: trimmed.surface, reading: reading)
            return TokenListItem(
                spanIndex: index,
                range: trimmed.range,
                surface: trimmed.surface,
                reading: reading,
                displayReading: displayReading,
                isAlreadySaved: alreadySaved
            )
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

    private func inlineTokenActionPanel(for selection: TokenSelectionContext) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            TokenActionPanel(
                selection: selection,
                lookup: inlineLookup,
                preferredReading: selection.annotatedSpan.readingKana,
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
                embedInMaterialBackground: true,
                focusSplitMenu: pendingSplitFocusSelectionID == selection.id,
                onSplitFocusConsumed: { pendingSplitFocusSelectionID = nil }
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
            assignInputTextFromExternalSource(note.text)
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
        } else if currentNote == nil,
                  inputText.isEmpty,
                  let lastID = lastOpenedNoteID,
                  let note = notes.notes.first(where: { $0.id == lastID }) {
            currentNote = note
            assignInputTextFromExternalSource(note.text)
            noteTitleInput = note.title ?? ""
            hasManuallyEditedTitle = (note.title?.isEmpty == false)
            setEditing(false, suppressRefresh: true)
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
                setEditing(false, suppressRefresh: true)
            }
            noteTitleInput = ""
            hasManuallyEditedTitle = false
        }
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
        pendingRouterResetNoteID = router.pendingResetNoteID
        processPendingRouterResetRequest()
        ensureInitialFuriganaReady(reason: "onAppear initialization")
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
        Self.selectionLogger.debug("Clearing selection resetPersistent=\(resetPersistent)")
        let hadSelection = selectionController.tokenSelection != nil
        selectionController.clearSelection(resetPersistent: resetPersistent)
        isDictionarySheetPresented = false
        Task { @MainActor in
            inlineLookup.results = []
            inlineLookup.errorMessage = nil
            inlineLookup.isLoading = false
        }
        if dictionaryPopupEnabled && hadSelection {
            Self.selectionLogger.debug("Dictionary popup hidden")
        }
    }

    private func handleInlineSpanSelection(_ selection: RubySpanSelection?) {
        guard let selection else {
            clearSelection()
            return
        }
        presentDictionaryForSpan(at: selection.spanIndex, focusSplitMenu: false)
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
        startSplitFlow(for: selection.spanIndex)
    }

    @MainActor
    private func beginPendingSelectionRestoration(for range: NSRange) {
        selectionController.beginPendingSelectionRestoration(for: range)
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

    private func dictionaryPanel(for selection: TokenSelectionContext, enableDragToDismiss: Bool, embedInMaterialBackground: Bool) -> TokenActionPanel {
        TokenActionPanel(
            selection: selection,
            lookup: inlineLookup,
            preferredReading: selection.annotatedSpan.readingKana,
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
            enableDragToDismiss: enableDragToDismiss,
            embedInMaterialBackground: embedInMaterialBackground,
            focusSplitMenu: pendingSplitFocusSelectionID == selection.id,
            onSplitFocusConsumed: { pendingSplitFocusSelectionID = nil }
        )
    }

    private func applyDictionarySheet<Content: View>(to view: Content) -> AnyView {
        if sheetDictionaryPanelEnabled {
            return AnyView(
                view.sheet(isPresented: $isDictionarySheetPresented, onDismiss: {
                    if dictionaryPopupEnabled {
                        Self.selectionLogger.debug("Dictionary popup dismissed by user")
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
                            .presentationDetents([
                                .height(max(sheetPanelHeight + 50, 300))
                            ])
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

    private func selectionContext(forSpanAt index: Int) -> TokenSelectionContext? {
        guard let spans = furiganaSpans else { return nil }
        guard spans.indices.contains(index) else { return nil }
        guard let trimmed = trimmedRangeAndSurface(for: spans[index].span.range) else { return nil }
        return TokenSelectionContext(
            spanIndex: index,
            range: trimmed.range,
            surface: trimmed.surface,
            annotatedSpan: spans[index]
        )
    }

    private func presentDictionaryForSpan(at index: Int, focusSplitMenu: Bool) {
        guard let context = selectionContext(forSpanAt: index) else { return }
        pendingSelectionRange = nil
        persistentSelectionRange = context.range
        tokenSelection = context
        if sheetDictionaryPanelEnabled {
            sheetSelection = context
            isDictionarySheetPresented = true
        }
        if dictionaryPopupEnabled {
            let r = context.range
            Self.selectionLogger.debug("Dictionary popup shown spanIndex=\(index) range=\(r.location)-\(NSMaxRange(r)) surface=\(context.surface, privacy: .public) inline=\(self.inlineDictionaryPanelEnabled) sheet=\(self.sheetDictionaryPanelEnabled)")
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
        guard let spans = furiganaSpans else { return }
        guard spans.indices.contains(index) else { return }
        guard let context = selectionContext(forSpanAt: index) else { return }
        let reading = normalizedReading(spans[index].readingKana)
        let surface = context.surface.trimmingCharacters(in: .whitespacesAndNewlines)

        // Toggle behavior: if already saved, delete; otherwise add
        if hasSavedWord(surface: surface, reading: reading) {
            let matches = words.words.filter { $0.surface == surface && $0.kana == reading }
            let ids = Set(matches.map { $0.id })
            if ids.isEmpty == false {
                words.delete(ids: ids)
            }
            return
        }

        Task {
            let entry = await lookupPreferredDictionaryEntry(surface: context.surface, reading: reading)
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
        let trimmedKanji = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKanji.isEmpty == false {
            return trimmedKanji
        }
        if let kana = normalizedReading(entry.kana) {
            return kana
        }
        return fallback
    }

    private func normalizedReading(_ reading: String?) -> String? {
        guard let value = reading?.trimmingCharacters(in: .whitespacesAndNewlines), value.isEmpty == false else { return nil }
        return value
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

    private func hasSavedWord(surface: String, reading: String?) -> Bool {
        words.words.contains { word in
            word.surface == surface && word.kana == reading
        }
    }

    private func tokenDuplicateKey(surface: String, reading: String?) -> String {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = reading?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(normalizedSurface)|\(normalizedReading)"
    }

    private func mergeSpan(at index: Int, direction: MergeDirection) {
        guard let spans = furiganaSpans else { return }
        guard spans.indices.contains(index) else { return }
        guard let neighborIndex = neighborIndex(for: index, direction: direction), spans.indices.contains(neighborIndex) else { return }
        let currentRange = spans[index].span.range
        let neighborRange = spans[neighborIndex].span.range
        let union = NSUnionRange(currentRange, neighborRange)
        let override = ReadingOverride(
            noteID: activeNoteID,
            rangeStart: union.location,
            rangeLength: union.length,
            userKana: nil
        )
        applyOverridesChange(range: union, newOverrides: [override], actionName: "Merge Tokens")
        persistentSelectionRange = union
        pendingSelectionRange = nil
        tokenSelection = nil
        if sheetDictionaryPanelEnabled {
            sheetSelection = nil
        }
    }

    private func startSplitFlow(for index: Int) {
        guard let spans = furiganaSpans else { return }
        guard spans.indices.contains(index) else { return }
        guard let trimmed = trimmedRangeAndSurface(for: spans[index].span.range), trimmed.range.length > 1 else { return }
        presentDictionaryForSpan(at: index, focusSplitMenu: true)
    }

    private func canMergeSpan(at index: Int, direction: MergeDirection) -> Bool {
        guard let spans = furiganaSpans else { return false }
        guard spans.indices.contains(index) else { return false }
        guard let neighbor = neighborIndex(for: index, direction: direction) else { return false }
        return spans.indices.contains(neighbor)
    }

    private func handleOverridesExternalChange() {
        let signature = computeOverrideSignature()
        guard signature != overrideSignature else { return }
        Self.selectionLogger.debug("Override change detected for note=\(activeNoteID)")
        overrideSignature = signature
        updateCustomizedRanges()
        guard inputText.isEmpty == false else { return }
        guard showFurigana || tokenHighlightsEnabled else { return }
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
            Self.logFurigana("Skipping refresh (\(reason)): paste text is empty.")
            return
        }
        furiganaRefreshToken &+= 1
        Self.logFurigana("Queued refresh token \(furiganaRefreshToken) for text length \(inputText.count). Reason: \(reason)")
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
            Self.logFurigana("No furigana task created because text is empty.")
            return nil
        }
        // Capture current values by value to avoid capturing self
        let currentText = inputText
        let currentShowFurigana = showFurigana
        let currentAlternateTokenColors = alternateTokenColors
        let currentHighlightUnknownTokens = highlightUnknownTokens
        let currentSpanConsumersActive = spanConsumersActive
        let currentTextSize = readingTextSize
        let currentFuriganaSize = readingFuriganaSize
        let currentSpans = furiganaSpans
        let currentOverrides = readingOverrides.overrides(for: activeNoteID)
        let pipelineInput = FuriganaPipelineService.Input(
            text: currentText,
            showFurigana: currentShowFurigana,
            needsTokenHighlights: currentSpanConsumersActive,
            textSize: currentTextSize,
            furiganaSize: currentFuriganaSize,
            recomputeSpans: recomputeSpans,
            existingSpans: currentSpans,
            overrides: currentOverrides,
            context: "PasteView"
        )
        let service = furiganaPipeline
        Self.logFurigana("Creating furigana task token \(token) for text length \(currentText.count). ShowF: \(currentShowFurigana)")
        return {
            let result = await service.render(pipelineInput)
            await MainActor.run {
                guard Task.isCancelled == false else {
                    Self.logFurigana("Discarded cancelled furigana task token \(token)")
                    return
                }
                guard token == furiganaRefreshToken else {
                    Self.logFurigana("Discarded stale furigana result token \(token); latest token is \(furiganaRefreshToken)")
                    return
                }
                guard inputText == currentText && showFurigana == currentShowFurigana else {
                    Self.logFurigana("Discarded furigana result token \(token) because state changed before apply")
                    return
                }
                furiganaSpans = result.spans
                Self.logFurigana("Applied spans: \(result.spans?.count ?? 0)")
                furiganaAttributedText = result.attributedString
                restoreSelectionIfNeeded()
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

    fileprivate static func logFurigana(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        let functionName = String(describing: function).replacingOccurrences(of: ":", with: " ")
        furiganaLogger.info("\(file) \(line) \(functionName) \(message, privacy: .public)")
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

private struct TokenListItem: Identifiable {
    let spanIndex: Int
    let range: NSRange
    let surface: String
    let reading: String?
    let displayReading: String?
    let isAlreadySaved: Bool

    var id: Int { spanIndex }
    var canSplit: Bool { range.length > 1 }
}

private struct TokenListPanel: View {
    let items: [TokenListItem]
    let isReady: Bool
    let isEditing: Bool
    let selectedRange: NSRange?
    let onSelect: (Int) -> Void
    let onGoTo: (Int) -> Void
    let onAdd: (Int) -> Void
    let onMergeLeft: (Int) -> Void
    let onMergeRight: (Int) -> Void
    let onSplit: (Int) -> Void
    let canMergeLeft: (Int) -> Bool
    let canMergeRight: (Int) -> Bool

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
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.surface)
                        .font(.body)
                        .lineLimit(1)
                    if let reading = readingText {
                        Text(reading)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
                Spacer(minLength: 12)
                Button(action: onAdd) {
                    if item.isAlreadySaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "star.circle")
                            .foregroundColor(.accentColor)
                    }
                }
                .font(.title3)
                .buttonStyle(.plain)
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

