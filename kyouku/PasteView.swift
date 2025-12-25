//
//  PasteView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//
import SwiftUI
import UIKit
import Foundation
import OSLog

struct PasteView: View {
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var words: WordsStore
    @EnvironmentObject var readingOverrides: ReadingOverridesStore
    @Environment(\.undoManager) private var undoManager

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
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

    @AppStorage("readingTextSize") private var readingTextSize: Double = 17
    @AppStorage("readingFuriganaSize") private var readingFuriganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var readingLineSpacing: Double = 4
    @AppStorage("readingShowFurigana") private var showFurigana: Bool = true
    @AppStorage("readingAlternateTokenColors") private var alternateTokenColors: Bool = false
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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    ControlCell {
                        Button(action: newNote) {
                            Image(systemName: "plus.square").font(.title2)
                        }
                        .accessibilityLabel("New Note")
                        .disabled(isEditing)
                    }

                    EditorContainer(
                        text: $inputText,
                        furiganaText: furiganaAttributedText,
                        furiganaSpans: furiganaSpans,
                        textSize: readingTextSize,
                        isEditing: isEditing,
                        showFurigana: showFurigana,
                        lineSpacing: readingLineSpacing,
                        alternateTokenColors: alternateTokenColors,
                        selectedRangeHighlight: persistentSelectionRange,
                        customizedRanges: customizedRanges,
                        onTokenSelection: handleTokenSelection,
                        onSelectionCleared: { clearSelection() }
                    )
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)

                    if tokenSelection == nil {
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

                if let selection = tokenSelection, selection.range.length > 0 {
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
                            isSelectionCustomized: selectionIsCustomized(selection)
                        )
                        .padding(.horizontal, 0)
                        .padding(.bottom, 0)
                        .ignoresSafeArea(edges: .bottom)
                    }
                    .zIndex(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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
        }
    }

    private func pasteFromClipboard() {
        if let str = UIPasteboard.general.string {
            inputText = str
            // Update current note's title to the first line of the pasted text
            let firstLine = str.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let existing = currentNote {
                // Update the note's title and text in the store
                notes.notes = notes.notes.map { n in
                    if n.id == existing.id {
                        return Note(id: n.id, title: firstLine.isEmpty ? nil : firstLine, text: str, createdAt: n.createdAt)
                    } else {
                        return n
                    }
                }
                notes.save()
                // Keep our local currentNote in sync
                if let updated = notes.notes.first(where: { $0.id == existing.id }) {
                    currentNote = updated
                }
            }
        }
    }

    private func saveNote() {
        guard !inputText.isEmpty else { return }
        if let existing = currentNote {
            notes.notes = notes.notes.map { n in
                if n.id == existing.id {
                    return Note(id: n.id, title: n.title, text: inputText, createdAt: n.createdAt)
                } else {
                    return n
                }
            }
            notes.save()
        } else {
            let firstLine = inputText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            let title = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            notes.addNote(title: (title?.isEmpty == true) ? nil : title, text: inputText)
            currentNote = notes.notes.first
        }
    }

    public func newNote() {
        hideKeyboard()
        setEditing(true)

        inputText = ""
        notes.addNote(title: nil, text: "")
        notes.save()

        if let newest = notes.notes.first {
            currentNote = newest
        } else if let last = notes.notes.last {
            currentNote = last
        } else {
            currentNote = nil
        }

        PasteBufferStore.save("")
        furiganaAttributedText = nil
        furiganaSpans = nil
    }

    private func onAppearHandler() {
        if let note = router.noteToOpen {
            currentNote = note
            inputText = note.text
            if router.pasteShouldBeginEditing {
                setEditing(true)
            } else {
                setEditing(false, suppressRefresh: true)
            }
            router.pasteShouldBeginEditing = false
            router.noteToOpen = nil
        }
        if !hasInitialized {
            if inputText.isEmpty {
                // Default to edit mode when starting with empty paste area
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
        }
        overrideSignature = computeOverrideSignature()
        updateCustomizedRanges()
    }

    private func syncNoteForInputChange(_ newValue: String) {
        // Keep current note's title synced to the first line of the text
        guard let existing = currentNote else { return }
        let firstLine = newValue.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        notes.notes = notes.notes.map { n in
            if n.id == existing.id {
                return Note(id: n.id, title: firstLine.isEmpty ? nil : firstLine, text: newValue, createdAt: n.createdAt)
            } else {
                return n
            }
        }
        notes.save()
        if let updated = notes.notes.first(where: { $0.id == existing.id }) {
            currentNote = updated
        }
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
        inlineLookup.results = []
        inlineLookup.errorMessage = nil
        inlineLookup.isLoading = false
    }

    private func handleSelectionLookup(for term: String) {
        guard term.isEmpty == false else {
            inlineLookup.results = []
            inlineLookup.errorMessage = nil
            inlineLookup.isLoading = false
            return
        }
        let lemmaFallbacks = tokenSelection?.annotatedSpan.lemmaCandidates ?? []
        Task { [lemmaFallbacks] in
            await inlineLookup.load(term: term, fallbackTerms: lemmaFallbacks)
        }
    }

    private func handleTokenSelection(_ payload: RubyText.SelectionPayload) {
        guard isEditing == false else { return }
        let range = payload.range
        guard range.location != NSNotFound, range.length > 0 else { return }
        let nsText = inputText as NSString
        guard NSMaxRange(range) <= nsText.length else { return }
        let surface = nsText.substring(with: range)
        Self.selectionLogger.debug("Token selected spanIndex=\(payload.index) range=\(range.location)-\(NSMaxRange(range)) surface=\(surface, privacy: .public)")
        persistentSelectionRange = range
        tokenSelection = TokenSelectionContext(
            spanIndex: payload.index,
            range: range,
            surface: surface,
            annotatedSpan: payload.span
        )
    }

    private func handleOverridesExternalChange() {
        let signature = computeOverrideSignature()
        guard signature != overrideSignature else { return }
        Self.selectionLogger.debug("Override change detected for note=\(activeNoteID)")
        overrideSignature = signature
        updateCustomizedRanges()
        guard inputText.isEmpty == false else { return }
        guard showFurigana || alternateTokenColors else { return }
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
        guard showFurigana || alternateTokenColors else {
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
        guard showFurigana || alternateTokenColors else {
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
                needsTokenHighlights: currentAlternateTokenColors,
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
                }
            }
        }
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
    var selectedRangeHighlight: NSRange?
    var customizedRanges: [NSRange]
    var onTokenSelection: ((RubyText.SelectionPayload) -> Void)? = nil
    var onSelectionCleared: (() -> Void)? = nil

    private let placeholder = "Paste or type Japanese text"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isEditing {
                editorContent
            } else if text.isEmpty {
                displayShell {
                    EmptyView()
                }
            } else if showFurigana {
                displayShell {
                    rubyBlock(annotationVisibility: .visible)
                        .fixedSize(horizontal: false, vertical: true) // prevent vertical compression
                }
            } else {
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
        TextEditor(text: $text)
            .font(.system(size: textSize))
            .lineSpacing(lineSpacing)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .foregroundColor(.primary)
            .padding(editorInsets)
    }

    private var editorInsets: EdgeInsets {
        let rubyHeadroom = max(0.0, textSize * 0.6 + lineSpacing)
        let topInset = max(8.0, rubyHeadroom)
        return EdgeInsets(top: CGFloat(topInset), leading: 11, bottom: 12, trailing: 12)
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
            tokenOverlays: tokenBorderOverlays,
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

    private var tokenBorderOverlays: [RubyText.TokenOverlay] {
        guard alternateTokenColors, let spans = furiganaSpans else { return [] }
        let palette: [UIColor] = [UIColor.systemBlue, UIColor.systemPink]
        guard palette.isEmpty == false else { return [] }
        let maxLength = furiganaText?.length ?? (text as NSString).length
        let coverageRanges = Self.coverageRanges(from: spans, textLength: maxLength)
        var overlays: [RubyText.TokenOverlay] = []
        overlays.reserveCapacity(coverageRanges.count)
        for (index, range) in coverageRanges.enumerated() {
            let color = palette[index % palette.count]
            overlays.append(RubyText.TokenOverlay(range: range, color: color))
        }
        return overlays
    }

    private static func coverageRanges(from spans: [AnnotatedSpan], textLength: Int) -> [NSRange] {
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
                ranges.append(NSRange(location: cursor, length: range.location - cursor))
            }
            ranges.append(range)
            cursor = max(cursor, NSMaxRange(range))
        }
        if cursor < textLength {
            ranges.append(NSRange(location: cursor, length: textLength - cursor))
        }
        return ranges
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

