//
//  PasteView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI
import UIKit
import Combine
import Foundation
import OSLog

fileprivate let popupLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Interaction")

struct PasteView: View {
    private static let furiganaSymbolOn = "furigana.on"
    private static let furiganaSymbolOff = "furigana.off"

    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var showFurigana: Bool = true
    @State private var showTokenHighlighting: Bool = false
    @State private var selectedToken: ParsedToken? = nil
    @State private var showingDefinition = false
    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil
    @State private var goExtract = false
    @State private var hasInitialized: Bool = false
    @State private var isEditing: Bool = false
    @State private var lookupTask: Task<Void, Never>? = nil
    @State private var lookupRequestID: UUID? = nil

    @State private var selectedEntryIndex: Int? = nil
    @State private var fallbackTranslation: String? = nil
    
    @State private var foregroundCancellable: Any? = nil

    @State private var isTrieReady: Bool = true
    @State private var boundaryVersion: Int = 0

    @AppStorage("perKanjiFuriganaEnabled") private var perKanjiFuriganaEnabled: Bool = true

    @AppStorage("readingTextSize") private var textSize: Double = 17
    @AppStorage("readingFuriganaSize") private var furiganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var lineSpacing: Double = 4
    @AppStorage("readingFuriganaGap") private var furiganaGap: Double = 2

    @State private var readingOverride: ReadingOverride? = nil

    var body: some View {
        NavigationStack {
            if isTrieReady {
                VStack(spacing: 16) {
                    HStack(alignment: .center, spacing: 8) {
                        
                        ControlCell {
                            Button(action: newNote) {
                                Image(systemName: "plus.square").font(.title2)
                            }
                            .accessibilityLabel("New Note")
                            .disabled(isEditing)
                        }

                        ControlCell {
                            Button(action: extractWords) {
                                Image(systemName: "arrowshape.turn.up.right").font(.title2)
                            }
                            .accessibilityLabel("Extract Words")
                            .disabled(isEditing)
                        }

                    }
                    EditorContainer(
                        text: $inputText,
                        showFurigana: showFurigana,
                        showTokenHighlighting: showTokenHighlighting,
                        isEditing: isEditing,
                        textSize: textSize,
                        furiganaSize: furiganaSize,
                        lineSpacing: lineSpacing,
                        furiganaGap: furiganaGap,
                        perKanjiSplit: perKanjiFuriganaEnabled,
                        highlightedToken: selectedToken,
                        onTokenTap: handleTokenTap,
                        onSelectionCleared: handleSelectionCleared,
                        boundaryVersion: boundaryVersion,
                        readingOverrides: readingOverride.map { [$0] } ?? []
                    )
                    
                    HStack(alignment: .center, spacing: 8) {
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

                        ControlCell {
                            Toggle(isOn: $showFurigana) {
                                Image(showFurigana ? Self.furiganaSymbolOn : Self.furiganaSymbolOff)
                            }
                            .labelsHidden()
                            .toggleStyle(.button)
                            .tint(.accentColor)
                            .font(.title2)
                            .disabled(isEditing)
                            .accessibilityLabel("Furigana")
                        }

//                        ControlCell {
//                            Toggle(isOn: $showTokenHighlighting) {
//                                if UIImage(systemName: "highlighter") != nil {
//                                    Image(systemName: "highlighter")
//                                } else {
//                                    Image(systemName: "paintbrush")
//                                }
//                            }
//                            .labelsHidden()
//                            .toggleStyle(.button)
//                            .tint(.accentColor)
//                            .font(.title2)
//                            .disabled(isEditing)
//                            .accessibilityLabel("Highlight tokens")
//                        }

//                        ControlCell {
//                            Button(action: clearInput) {
//                                Image(systemName: "trash").font(.title2)
//                            }
//                            .accessibilityLabel("Clear")
//                        }
                    }
                    .controlSize(.small)
                    .padding(.horizontal)

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 24) }
                .sheet(isPresented: $showingDefinition) {
                    DefinitionSheetContent(
                        selectedToken: $selectedToken,
                        showingDefinition: $showingDefinition,
                        dictResults: $dictResults,
                        isLookingUp: $isLookingUp,
                        lookupError: $lookupError,
                        selectedEntryIndex: $selectedEntryIndex,
                        fallbackTranslation: $fallbackTranslation,
                        onAdd: onAddDefinition
                    )
                    .environmentObject(store)
                }
                .navigationDestination(isPresented: $goExtract) {
                    ExtractWordsView(text: inputText)
                }
                .navigationTitle(currentNote?.title ?? "Paste")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear(perform: onAppearHandler)
                .onDisappear {
                    NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
                    NotificationCenter.default.removeObserver(self, name: .applyReadingOverride, object: nil)
                    lookupTask?.cancel()
                }
                .onChange(of: inputText) { _, newValue in
                    syncNoteForInputChange(newValue)
                    PasteBufferStore.save(newValue)
                }
                .onChange(of: isEditing) { _, nowEditing in
                    onEditingChanged(nowEditing)
                }
                .onReceive(NotificationCenter.default.publisher(for: .customTokenizerLexiconDidChange)) { _ in
                    Task {
                        let rebuilt = await TokenizerBoundaryManager.rebuildSharedTrie()
                        await MainActor.run {
                            if let rebuilt {
                                JMdictTrieCache.shared = rebuilt
                            }
                            boundaryVersion &+= 1
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView("Preparing dictionary…")
                    Text("Loading tokenizer…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handleTokenTap(_ token: ParsedToken) {
        selectedToken = token
        showingDefinition = true
        // Cancel any previous lookup task
        lookupTask?.cancel()
        fallbackTranslation = nil

        let requestID = UUID()
        lookupRequestID = requestID

        // Reset UI state on the main actor in a separate lightweight task
        Task { @MainActor in
            guard lookupRequestID == requestID else { return }
            isLookingUp = true
            lookupError = nil
            dictResults = []
            selectedEntryIndex = nil
        }

        // Start a fresh lookup task
        let newTask = Task {
            await lookupDefinitions(for: token, requestID: requestID)
        }
        lookupTask = newTask
    }

    private func handleSelectionCleared() {
        lookupTask?.cancel()
        lookupTask = nil
        lookupRequestID = nil
        selectedToken = nil
        showingDefinition = false
        isLookingUp = false
        lookupError = nil
        dictResults = []
        selectedEntryIndex = nil
        fallbackTranslation = nil
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

    private func extractWords() {
        goExtract = true
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
        // End any editing session and reset lookup UI
        hideKeyboard()
        isEditing = true
        showFurigana = false
        showingDefinition = false
        selectedToken = nil
        lookupTask?.cancel()
        isLookingUp = false
        lookupError = nil
        dictResults = []
        selectedEntryIndex = nil
        lookupRequestID = nil
        fallbackTranslation = nil

        // Clear current editor text and create a fresh note in the store
        inputText = ""
        notes.addNote(title: nil, text: "")
        notes.save()

        // Set the currentNote to the newly created note (assumes addNote appends newest first or last)
        if let newest = notes.notes.first {
            currentNote = newest
        } else if let last = notes.notes.last {
            currentNote = last
        } else {
            currentNote = nil
        }

        // Persist empty paste buffer state
        PasteBufferStore.save("")
    }

    private func clearInput() {
        inputText = ""
    }

    private func onAddDefinition(token: ParsedToken, filteredResults: [DictionaryEntry], selectionIndex: Int?, translation: String?) {
        func entry(at index: Int?) -> DictionaryEntry? {
            guard let idx = index, idx >= 0, idx < filteredResults.count else { return filteredResults.first }
            return filteredResults[idx]
        }

        // Detect if this is a custom translation input (translation is non-nil and selectionIndex == nil)
        // But we have changed the UI so translation param may be just the "meaning" from custom fields.
        // We will update callsite to pass a special custom translation struct-like or nil for normal.

        let chosenEntry = entry(at: selectionIndex)
        let hasKanjiInToken: Bool = token.surface.contains { ch in
            ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
        }

        // We need to distinguish if the call is from custom translation screen or normal add.
        // The DefinitionSheetContent changed to pass custom fields in translation param,
        // so now translation param is the "meaning" string only, and selectionIndex can be nil indicating custom input.

        if selectionIndex == nil {
            // This is the custom translation add. 
            // The onAdd call will contain translation string representing meaning, but we need also the Kanji and Furigana from the UI.
            // The onAdd call is from DefinitionSheetContent; it passes (token, filteredResults, nil, meaning).
            // But to get Kanji and Furigana, we need to pass them from DefinitionSheetContent as well.
            // Since the signature does not pass Kanji and Furigana separately, we must update onAdd signature or workaround.
            // As per instructions, we must use the values from the three fields on the custom screen.

            // So here, to stay consistent, only add surface/reading/meaning if translation is non-empty.

            // But since onAdd only has token, filteredResults, selectionIndex, translation, we cannot get Kanji and Furigana from here.
            // We will put the logic in DefinitionSheetContent onAdd closure, and call store.add() directly there for custom.

            // So here, do nothing.
            // Actually, to avoid confusion, do nothing here.
            return
        }

        if let customTranslation = translation, !customTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Use custom translation if present and not empty
            let kanaSurface = token.reading.isEmpty ? token.surface : token.reading
            store.add(surface: kanaSurface, reading: token.reading, meaning: customTranslation, sourceNoteID: currentNote?.id)
            return
        }
        if !hasKanjiInToken {
            if let entry = chosenEntry {
                let kanaSurface = token.reading.isEmpty ? token.surface : token.reading
                let glossSource = entry.gloss
                let firstGloss = glossSource.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? glossSource
                let t = ParsedToken(surface: kanaSurface, reading: entry.reading, meaning: firstGloss)
                store.add(surface: t.surface, reading: t.reading, meaning: t.meaning!, sourceNoteID: currentNote?.id)
            } else if let translation, translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                let kanaSurface = token.reading.isEmpty ? token.surface : token.reading
                store.add(surface: kanaSurface, reading: token.reading, meaning: translation, sourceNoteID: currentNote?.id)
            } else {
                store.add(surface: token.surface, reading: token.reading, meaning: token.meaning!, sourceNoteID: currentNote?.id)
            }
        } else {
            if let entry = chosenEntry {
                let surface = (entry.kanji.isEmpty == false) ? entry.kanji : entry.reading
                let glossSource = entry.gloss
                let firstGloss = glossSource.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? glossSource
                let t = ParsedToken(surface: surface, reading: entry.reading, meaning: firstGloss)
                store.add(surface: t.surface, reading: t.reading, meaning: t.meaning!, sourceNoteID: currentNote?.id)
            } else if let translation, translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                store.add(surface: token.surface, reading: token.reading, meaning: translation, sourceNoteID: currentNote?.id)
            } else {
                store.add(surface: token.surface, reading: token.reading, meaning: token.meaning!, sourceNoteID: currentNote?.id)
            }
        }
    }

    private func onAppearHandler() {
        if JMdictTrieCache.shared == nil {
            // Render UI immediately; build trie lazily in background
            isTrieReady = true
            Task {
                let trie = await JMdictTrieProvider.shared.getTrie() ?? CustomTrieProvider.makeTrie()
                if let trie {
                    await MainActor.run {
                        JMdictTrieCache.shared = trie
                    }
                }
            }
        } else {
            isTrieReady = true
        }
        if let note = router.noteToOpen {
            currentNote = note
            inputText = note.text
            isEditing = false
            showFurigana = true
            router.noteToOpen = nil
        }
        if !hasInitialized {
            if inputText.isEmpty {
                // Default to edit mode when starting with empty paste area
                isEditing = true
            }
            hasInitialized = true
        }
        if currentNote == nil && inputText.isEmpty {
            let persisted = PasteBufferStore.load()
            if !persisted.isEmpty {
                inputText = persisted
                // If we restored text, default to viewing mode (furigana on) unless user starts editing
                isEditing = false
                showFurigana = true
            }
        }
        ingestSharedInbox()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            ingestSharedInbox()
        }

        NotificationCenter.default.addObserver(forName: .applyReadingOverride, object: nil, queue: .main) { note in
            if let ov = note.object as? ReadingOverride {
                readingOverride = ov
                boundaryVersion &+= 1
            }
        }
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

    private func onEditingChanged(_ nowEditing: Bool) {
        if nowEditing {
            // Ensure the editor is in plain text mode to allow editing and show keyboard
            showFurigana = false
            // Dismiss popups and cancel any ongoing lookups
            showingDefinition = false
            selectedToken = nil
            lookupTask?.cancel()
            isLookingUp = false
            lookupError = nil
            dictResults = []
            selectedEntryIndex = nil
            lookupRequestID = nil
            fallbackTranslation = nil
        }
    }

    private struct TimeoutError: Error {}

    private func withTimeout<T>(_ seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    
    private func ingestSharedInbox() {
        if let shared = SharedInbox.takeLatestText(), !shared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = shared
            // Switch to viewing mode unless the user prefers editing
            if inputText.isEmpty == false { isEditing = false }
        }
    }

    private func lookupDefinitions(for token: ParsedToken, requestID: UUID) async {
        if Task.isCancelled {
            await MainActor.run {
                if lookupRequestID == requestID {
                    isLookingUp = false
                    lookupTask = nil
                }
            }
            return
        }

        let cleanup = {
            Task { @MainActor in
                if lookupRequestID == requestID {
                    isLookingUp = false
                    lookupTask = nil
                }
            }
        }
        defer { _ = cleanup() }

        let rawSurface = token.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawReading = token.reading.trimmingCharacters(in: .whitespacesAndNewlines)

        // Guard against empty input
        if rawSurface.isEmpty && rawReading.isEmpty {
            await MainActor.run {
                if lookupRequestID == requestID {
                    isLookingUp = false
                }
                lookupError = "Empty selection."
                dictResults = []
            }
            return
        }

        await MainActor.run {
            guard lookupRequestID == requestID else { return }
            isLookingUp = true
            lookupError = nil
            dictResults = []
            selectedEntryIndex = nil
            fallbackTranslation = nil
        }
        do {
            // Basic sanitation: remove trailing punctuation that often appears in tokenization
            let sanitizedSurface = rawSurface.trimmingCharacters(in: CharacterSet(charactersIn: "。、，,.!？?；;：:"))
            let sanitizedReading = rawReading.trimmingCharacters(in: CharacterSet(charactersIn: "。、，,.!？?；;：:"))

            var all: [DictionaryEntry] = []
            let limit = 10

            func appendUnique(_ new: [DictionaryEntry]) {
                for n in new {
                    if !all.contains(where: { $0.kanji == n.kanji && $0.reading == n.reading && $0.gloss == n.gloss }) {
                        all.append(n)
                    }
                }
            }

            // Each lookup gets a timeout to avoid hanging the UI
            let timeoutSeconds = 3.0

            if !rawSurface.isEmpty && !Task.isCancelled {
                let q1 = try await withTimeout(timeoutSeconds) { try await DictionarySQLiteStore.shared.lookup(term: rawSurface, limit: limit) }
                appendUnique(q1)
            }

            if all.isEmpty && !rawReading.isEmpty && !Task.isCancelled {
                let q2 = try await withTimeout(timeoutSeconds) { try await DictionarySQLiteStore.shared.lookup(term: rawReading, limit: limit) }
                appendUnique(q2)
            }

            if all.isEmpty && !sanitizedSurface.isEmpty && sanitizedSurface != rawSurface && !Task.isCancelled {
                let q3 = try await withTimeout(timeoutSeconds) { try await DictionarySQLiteStore.shared.lookup(term: sanitizedSurface, limit: limit) }
                appendUnique(q3)
            }

            if all.isEmpty && !sanitizedReading.isEmpty && sanitizedReading != rawReading && !Task.isCancelled {
                let q4 = try await withTimeout(timeoutSeconds) { try await DictionarySQLiteStore.shared.lookup(term: sanitizedReading, limit: limit) }
                appendUnique(q4)
            }

            if Task.isCancelled {
                return
            }

            let hasKanjiInToken: Bool = token.surface.contains { ch in
                ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
            }
            func score(entry e: DictionaryEntry, token t: ParsedToken, hasKanji: Bool) -> (Int, Int, Int, Int) {
                // Higher tuple sorts earlier. We'll negate where needed for ascending.
                // Prefer camelCase property if available; default to 0 if neither exists
                let common = (e.isCommon ? 1 : 0)
                let surfaceCandidate = (e.kanji.isEmpty == false) ? (e.kanji) : (e.reading)
                let surfaceMatch = hasKanji ? ((surfaceCandidate == t.surface) ? 1 : 0) : 0
                let readingMatch = (!hasKanji ? (((e.reading) == (t.reading.isEmpty ? t.surface : t.reading)) ? 1 : 0) : 0)
                let glossSource = e.gloss
                let firstGloss = glossSource.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? glossSource
                // Sort keys: common desc, surfaceMatch desc, readingMatch desc, glossLength asc
                return (common, surfaceMatch, readingMatch, -firstGloss.count)
            }
            let sorted = all.sorted { a, b in
                let sa = score(entry: a, token: token, hasKanji: hasKanjiInToken)
                let sb = score(entry: b, token: token, hasKanji: hasKanjiInToken)
                return sa > sb
            }
            await MainActor.run {
                guard lookupRequestID == requestID else { return }
                dictResults = sorted
            }

            if sorted.isEmpty && !Task.isCancelled {
                if let fallback = await TranslationFallback.translate(surface: rawSurface, reading: rawReading) {
                    await MainActor.run {
                        guard lookupRequestID == requestID else { return }
                        fallbackTranslation = fallback
                    }
                }
            } else {
                await MainActor.run {
                    guard lookupRequestID == requestID else { return }
                    fallbackTranslation = nil
                }
            }
        } catch {
            await MainActor.run {
                guard lookupRequestID == requestID else { return }
                if error is TimeoutError {
                    lookupError = "Lookup timed out. Please try again."
                } else {
                    lookupError = (error as? DictionarySQLiteError)?.description ?? error.localizedDescription
                }
                fallbackTranslation = nil
            }
        }
    }

    private struct EditorContainer: View {
        @Binding var text: String
        var showFurigana: Bool
        var showTokenHighlighting: Bool
        var isEditing: Bool
        var textSize: Double
        var furiganaSize: Double
        var lineSpacing: Double
        var furiganaGap: Double
        var perKanjiSplit: Bool
        var highlightedToken: ParsedToken?
        var onTokenTap: (ParsedToken) -> Void
        var onSelectionCleared: () -> Void
        var boundaryVersion: Int
        var readingOverrides: [ReadingOverride]

        @State private var viewKey: Int = 0

        var body: some View {
            let allowTap = !isEditing
            let highlightColor = Color.yellow.opacity(0.25)
            let selectionColor = Color.accentColor.opacity(0.35)

            buildEditor(allowTap: allowTap, highlightColor: highlightColor, selectionColor: selectionColor, readingOverrides: readingOverrides)
                .onChange(of: textSize) { _, _ in bumpKey() }
                .onChange(of: furiganaSize) { _, _ in bumpKey() }
                .onChange(of: lineSpacing) { _, _ in bumpKey() }
                .onChange(of: furiganaGap) { _, _ in bumpKey() }
                .onChange(of: showFurigana) { _, _ in bumpKey() }
                .onChange(of: isEditing) { _, _ in bumpKey() }
                .onChange(of: showTokenHighlighting) { _, _ in bumpKey() }
                .onChange(of: perKanjiSplit) { _, _ in bumpKey() }
                .onChange(of: boundaryVersion) { _, _ in bumpKey() }
        }

        private func bumpKey() {
            // Force a lightweight view refresh without huge string interpolation
            viewKey &+= 1
        }

        private func buildEditor(allowTap: Bool, highlightColor: Color, selectionColor: Color, readingOverrides: [ReadingOverride]) -> some View {
            FuriganaTextEditor(
                text: $text,
                showFurigana: showFurigana,
                isEditable: isEditing,
                allowTokenTap: allowTap,
                onTokenTap: onTokenTap,
                onSelectionCleared: onSelectionCleared,
                showSegmentHighlighting: showTokenHighlighting,
                perKanjiSplit: perKanjiSplit,
                baseFontSize: textSize,
                rubyFontSize: furiganaSize,
                lineSpacing: lineSpacing,
                readingOverrides: readingOverrides
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color.clear)
            .environment(\.furiganaGap, furiganaGap)
            .environment(\.highlightedToken, highlightedToken)
            .environment(\.tokenHighlightColor, highlightColor)
            .environment(\.selectionHighlightColor, selectionColor)
            .environment(\.avoidOverlappingHighlights, true)
            .id(viewKey)
            .cornerRadius(12)
            .padding(.horizontal)
            .frame(maxHeight: .infinity)
            .clipped()
        }
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

private struct FuriganaGapKey: EnvironmentKey {
    static let defaultValue: Double = 2
}

extension EnvironmentValues {
    var furiganaGap: Double {
        get { self[FuriganaGapKey.self] }
        set { self[FuriganaGapKey.self] = newValue }
    }
}

private struct HighlightedTokenKey: EnvironmentKey {
    static let defaultValue: ParsedToken? = nil
}

extension EnvironmentValues {
    var highlightedToken: ParsedToken? {
        get { self[HighlightedTokenKey.self] }
        set { self[HighlightedTokenKey.self] = newValue }
    }
}

private struct TokenHighlightColorKey: EnvironmentKey {
    static let defaultValue: Color = .yellow.opacity(0.25)
}

private struct SelectionHighlightColorKey: EnvironmentKey {
    static let defaultValue: Color = .blue.opacity(0.35)
}

private struct AvoidOverlappingHighlightsKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var tokenHighlightColor: Color {
        get { self[TokenHighlightColorKey.self] }
        set { self[TokenHighlightColorKey.self] = newValue }
    }
    var selectionHighlightColor: Color {
        get { self[SelectionHighlightColorKey.self] }
        set { self[SelectionHighlightColorKey.self] = newValue }
    }
    var avoidOverlappingHighlights: Bool {
        get { self[AvoidOverlappingHighlightsKey.self] }
        set { self[AvoidOverlappingHighlightsKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted when the custom tokenizer lexicon changes and token boundaries may need refreshing.
    static let customTokenizerLexiconDidChange = Notification.Name("customTokenizerLexiconDidChange")
}

extension Notification.Name {
    static let applyReadingOverride = Notification.Name("applyReadingOverride")
}

// Re-open PasteView to keep type scope intact if needed
extension PasteView {
    /// Static helper to create a new note from outside PasteView.
    /// This mirrors the instance `newNote()` behavior for NotesView and others.
    static func createNewNote(notes: NotesStore, router: AppRouter) {
        // Create a fresh empty note and save
        notes.addNote(title: nil, text: "")
        notes.save()

        // Route to the Paste tab so the user can edit the new note there
        router.noteToOpen = notes.notes.first ?? notes.notes.last
        router.selectedTab = .paste

        // Also clear the persisted paste buffer
        PasteBufferStore.save("")
    }
}

