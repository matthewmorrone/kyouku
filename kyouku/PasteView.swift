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
    private static let furiganaSymbolOn = "furigana.on" // Replace with your actual symbol name
    private static let furiganaSymbolOff = "furigana.off"      // Replace with your actual symbol name

    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var showFurigana: Bool = true
    @State private var showTokenHighlighting: Bool = true
    @State private var selectedToken: ParsedToken? = nil
    @State private var showingDefinition = false
    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil
    @State private var goExtract = false
    @State private var hasInitialized: Bool = false
    @State private var isEditing: Bool = false
    @State private var lookupTask: Task<Void, Never>? = nil

    @State private var selectedEntryIndex: Int? = nil
    @State private var showAllDefinitions: Bool = false
    
    @State private var foregroundCancellable: Any? = nil

    @State private var isTrieReady: Bool = true

    @AppStorage("readingTextSize") private var textSize: Double = 17
    @AppStorage("readingFuriganaSize") private var furiganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var lineSpacing: Double = 4
    @AppStorage("readingFuriganaGap") private var furiganaGap: Double = 2

    var body: some View {
        NavigationStack {
            if isTrieReady {
                VStack(spacing: 16) {
                    
                    EditorContainer(
                        text: $inputText,
                        showFurigana: showFurigana,
                        showTokenHighlighting: showTokenHighlighting,
                        isEditing: isEditing,
                        textSize: textSize,
                        furiganaSize: furiganaSize,
                        lineSpacing: lineSpacing,
                        furiganaGap: furiganaGap,
                        highlightedToken: selectedToken,
                        onTokenTap: handleTokenTap
                    )
                    
                    HStack(alignment: .center, spacing: 8) {
                        ControlCell {
                            Button { hideKeyboard() } label: {
                                Image(systemName: "keyboard.chevron.compact.down").font(.title2)
                            }
                            .accessibilityLabel("Hide keyboard")
                        }

                        ControlCell {
                            Button(action: pasteFromClipboard) {
                                Image(systemName: "doc.on.clipboard").font(.title2)
                            }
                            .accessibilityLabel("Paste")
                        }

                        ControlCell {
                            Button(action: extractWords) {
                                Image(systemName: "arrowshape.turn.up.right").font(.title2)
                            }
                            .accessibilityLabel("Extract Words")
                            .disabled(isEditing)
                        }

                        ControlCell {
                            Button(action: saveNote) {
                                Image(systemName: "square.and.pencil").font(.title2)
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
                            .accessibilityLabel("Edit mode")
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
                            .accessibilityLabel("Show Furigana")
                        }

                        ControlCell {
                            Toggle(isOn: $showTokenHighlighting) {
                                if UIImage(systemName: "highlighter") != nil {
                                    Image(systemName: "highlighter")
                                } else {
                                    Image(systemName: "paintbrush")
                                }
                            }
                            .labelsHidden()
                            .toggleStyle(.button)
                            .tint(.accentColor)
                            .font(.title2)
                            .disabled(isEditing)
                            .accessibilityLabel("Highlight tokens")
                        }

                        ControlCell {
                            Button(action: clearInput) {
                                Image(systemName: "trash").font(.title2)
                            }
                            .accessibilityLabel("Clear")
                        }
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
                        showAllDefinitions: $showAllDefinitions,
                        onAdd: onAddDefinition
                    )
                }
                .navigationDestination(isPresented: $goExtract) {
                    ExtractWordsView(text: inputText)
                }
                .navigationTitle(currentNote?.title ?? "Paste")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear(perform: onAppearHandler)
                .onDisappear {
                    NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
                    lookupTask?.cancel()
                }
                .onChange(of: inputText) { _, newValue in
                    syncNoteForInputChange(newValue)
                    PasteBufferStore.save(newValue)
                }
                .onChange(of: isEditing) { _, nowEditing in
                    onEditingChanged(nowEditing)
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

        // Reset UI state on the main actor in a separate lightweight task
        Task { @MainActor in
            isLookingUp = true
            lookupError = nil
            dictResults = []
            selectedEntryIndex = nil
            showAllDefinitions = false
        }

        // Start a fresh lookup task
        let newTask = Task {
            await lookupDefinitions(for: token)
        }
        lookupTask = newTask
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

    private func clearInput() {
        inputText = ""
    }

    private func onAddDefinition(token: ParsedToken, filteredResults: [DictionaryEntry]) {
        let hasKanjiInToken: Bool = token.surface.contains { ch in
            ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
        }
        if !hasKanjiInToken {
            if let first = filteredResults.first {
                let kanaSurface = token.reading.isEmpty ? token.surface : token.reading
                let glossSource = first.gloss
                let firstGloss = glossSource.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? glossSource
                let t = ParsedToken(surface: kanaSurface, reading: first.reading, meaning: firstGloss)
                store.add(surface: t.surface, reading: t.reading, meaning: t.meaning!)
            } else {
                store.add(surface: token.surface, reading: token.reading, meaning: token.meaning!)
            }
        } else {
            if let first = filteredResults.first {
                let surface = (first.kanji.isEmpty == false) ? (first.kanji) : (first.reading)
                let glossSource = first.gloss
                let firstGloss = glossSource.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? glossSource
                let t = ParsedToken(surface: surface, reading: first.reading, meaning: firstGloss)
                store.add(surface: t.surface, reading: t.reading, meaning: t.meaning!)
            } else {
                store.add(surface: token.surface, reading: token.reading, meaning: token.meaning!)
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
            showAllDefinitions = false
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

    private func lookupDefinitions(for token: ParsedToken) async {
        if Task.isCancelled { return }

        let rawSurface = token.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawReading = token.reading.trimmingCharacters(in: .whitespacesAndNewlines)

        // Guard against empty input
        if rawSurface.isEmpty && rawReading.isEmpty {
            await MainActor.run {
                isLookingUp = false
                lookupError = "Empty selection."
                dictResults = []
            }
            return
        }

        await MainActor.run {
            isLookingUp = true
            lookupError = nil
            dictResults = []
            selectedEntryIndex = nil
            showAllDefinitions = false
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
                await MainActor.run {
                    isLookingUp = false
                }
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
                dictResults = sorted
                isLookingUp = false
            }
        } catch {
            await MainActor.run {
                if error is TimeoutError {
                    lookupError = "Lookup timed out. Please try again."
                } else {
                    lookupError = (error as? DictionarySQLiteError)?.description ?? error.localizedDescription
                }
                isLookingUp = false
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
        var highlightedToken: ParsedToken?
        var onTokenTap: (ParsedToken) -> Void

        @State private var viewKey: Int = 0

        var body: some View {
            let allowTap = showFurigana && !isEditing
            FuriganaTextEditor(
                text: $text,
                showFurigana: showFurigana,
                isEditable: isEditing,
                allowTokenTap: allowTap,
                onTokenTap: onTokenTap,
                showSegmentHighlighting: showTokenHighlighting,
                baseFontSize: textSize,
                rubyFontSize: furiganaSize,
                lineSpacing: lineSpacing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color.clear)
            .environment(\.furiganaGap, furiganaGap)
            .environment(\.highlightedToken, highlightedToken)
            .environment(\.tokenHighlightColor, Color.yellow.opacity(0.25))
            .environment(\.selectionHighlightColor, Color.accentColor.opacity(0.35))
            .environment(\.avoidOverlappingHighlights, true)
            .id(viewKey)
            .cornerRadius(12)
            .padding(.horizontal)
            .frame(maxHeight: .infinity)
            .clipped()
            .onChange(of: textSize) { _, _ in bumpKey() }
            .onChange(of: furiganaSize) { _, _ in bumpKey() }
            .onChange(of: lineSpacing) { _, _ in bumpKey() }
            .onChange(of: furiganaGap) { _, _ in bumpKey() }
            .onChange(of: showFurigana) { _, _ in bumpKey() }
            .onChange(of: isEditing) { _, _ in bumpKey() }
            .onChange(of: showTokenHighlighting) { _, _ in bumpKey() }
        }

        private func bumpKey() {
            // Force a lightweight view refresh without huge string interpolation
            viewKey &+= 1
        }
    }
}

// New extracted DefinitionSheetContent view
private struct DefinitionSheetContent: View {
    @Binding var selectedToken: ParsedToken?
    @Binding var showingDefinition: Bool
    @Binding var dictResults: [DictionaryEntry]
    @Binding var isLookingUp: Bool
    @Binding var lookupError: String?
    @Binding var selectedEntryIndex: Int?
    @Binding var showAllDefinitions: Bool
    var onAdd: (ParsedToken, [DictionaryEntry]) -> Void

    var body: some View {
        Group {
            if let token = selectedToken {
                let hasKanjiInToken: Bool = token.surface.contains { ch in
                    ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
                }
                let filteredResults: [DictionaryEntry] = {
                    if !hasKanjiInToken {
                        return dictResults.filter { ($0.reading) == (token.reading.isEmpty ? token.surface : token.reading) }
                    } else {
                        return dictResults
                    }
                }()
                let entry = filteredResults.first
                let displayKanji: String = {
                    if !hasKanjiInToken {
                        return token.reading.isEmpty ? token.surface : token.reading
                    }
                    if let e = entry {
                        return (e.kanji.isEmpty == false) ? (e.kanji) : (e.reading)
                    }
                    return token.surface
                }()
                let displayKana: String = entry?.reading ?? token.reading

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: {
                            onAdd(token, filteredResults)
                            showingDefinition = false
                            selectedEntryIndex = nil
                            showAllDefinitions = false
                        }) {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        Spacer()
                        Button(action: { showingDefinition = false }) {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                        }
                    }

                    Text(displayKanji)
                        .font(.title2).bold()

                    if !displayKana.isEmpty && displayKana != displayKanji {
                        Text(displayKana)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    if isLookingUp {
                        ProgressView("Looking up definitions…")
                    } else if let err = lookupError {
                        Text(err).foregroundStyle(.secondary)
                    } else if filteredResults.isEmpty {
                        Text("No definitions found.")
                            .foregroundStyle(.secondary)
                    } else {
                        DefinitionList(
                            filteredResults: filteredResults,
                            showAllDefinitions: $showAllDefinitions
                        )
                    }
                }
                .onAppear {
                    popupLogger.info("Dictionary popup: word='\(displayKanji, privacy: .public)', kana='\(displayKana, privacy: .public)'")
                }
                .onChange(of: dictResults) { _, _ in
                    // Recompute display values when results update to log the current header
                    let hasKanjiInToken = token.surface.contains { ch in
                        ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
                    }
                    let filtered: [DictionaryEntry] = {
                        if !hasKanjiInToken {
                            return dictResults.filter { ($0.reading) == (token.reading.isEmpty ? token.surface : token.reading) }
                        } else {
                            return dictResults
                        }
                    }()
                    let entry = filtered.first
                    let currentKanji: String = {
                        if !hasKanjiInToken {
                            return token.reading.isEmpty ? token.surface : token.reading
                        }
                        if let e = entry {
                            return (e.kanji.isEmpty == false) ? (e.kanji) : (e.reading)
                        }
                        return token.surface
                    }()
                    let currentKana: String = entry?.reading ?? token.reading
                    popupLogger.info("Dictionary popup updated: word='\(currentKanji, privacy: .public)', kana='\(currentKana, privacy: .public)'")
                }
                .padding()
                .presentationDetents([.fraction(0.33)])
                .presentationDragIndicator(.visible)
            } else {
                Text("No selection").padding()
            }
        }
    }
}

private struct DefinitionList: View {
    let filteredResults: [DictionaryEntry]
    @Binding var showAllDefinitions: Bool

    var body: some View {
        let maxShown = showAllDefinitions ? filteredResults.count : min(3, filteredResults.count)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<maxShown, id: \.self) { idx in
                let e = filteredResults[idx]
                let glossSource = e.gloss
                let firstGloss = glossSource.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? glossSource
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(firstGloss)
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            if filteredResults.count > 3 {
                Button(showAllDefinitions ? "Show fewer" : "View more") {
                    showAllDefinitions.toggle()
                }
                .font(.callout)
            }
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

// Re-open PasteView to keep type scope intact if needed
extension PasteView {}

