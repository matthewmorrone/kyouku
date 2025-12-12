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

struct PasteView: View {
    private static let furiganaSymbolOn = "furigana.on" // Replace with your actual symbol name
    private static let furiganaSymbolOff = "furigana.off"      // Replace with your actual symbol name

    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notes: NotesStore
    @EnvironmentObject var router: AppRouter

    @State private var inputText: String = ""
    @State private var currentNote: Note? = nil
    @State private var showFurigana: Bool = true
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

    @AppStorage("readingTextSize") private var textSize: Double = 17
    @AppStorage("readingFuriganaSize") private var furiganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var lineSpacing: Double = 4
    @AppStorage("readingFuriganaGap") private var furiganaGap: Double = 2

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                
                EditorContainer(
                    text: $inputText,
                    showFurigana: showFurigana,
                    isEditing: isEditing,
                    textSize: textSize,
                    furiganaSize: furiganaSize,
                    lineSpacing: lineSpacing,
                    furiganaGap: furiganaGap,
                    highlightedToken: selectedToken,
                    onTokenTap: { token in
                        selectedToken = token
                        showingDefinition = true
                        lookupTask?.cancel()
                        lookupTask = Task { @MainActor in
                            // flip UI state immediately on main actor
                            isLookingUp = true
                            lookupError = nil
                            dictResults = []
                            selectedEntryIndex = nil
                            showAllDefinitions = false
                        }
                        lookupTask = Task {
                            await lookupDefinitions(for: token)
                        }
                    }
                )
                
                HStack(alignment: .center, spacing: 8) {
                    ControlCell {
                        Button { hideKeyboard() } label: {
                            Image(systemName: "keyboard.chevron.compact.down").font(.title2)
                        }
                        .accessibilityLabel("Hide keyboard")
                    }

                    ControlCell {
                        Button {
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
                        } label: {
                            Image(systemName: "doc.on.clipboard").font(.title2)
                        }
                        .accessibilityLabel("Paste")
                    }

                    ControlCell {
                        Button { goExtract = true } label: {
                            Image(systemName: "arrowshape.turn.up.right").font(.title2)
                        }
                        .accessibilityLabel("Extract Words")
                        .disabled(isEditing)
                    }

                    ControlCell {
                        Button {
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
                        } label: {
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
                        Button { inputText = "" } label: {
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
                    onAdd: { token, filteredResults in
                        let hasKanjiInToken: Bool = token.surface.contains { ch in
                            ("\u{4E00}"..."\u{9FFF}").contains(String(ch))
                        }
                        if !hasKanjiInToken {
                            if let first = filteredResults.first {
                                let kanaSurface = token.reading.isEmpty ? token.surface : token.reading
                                let firstGloss = first.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? first.gloss
                                let t = ParsedToken(surface: kanaSurface, reading: first.reading, meaning: firstGloss)
                                store.add(from: t)
                            } else {
                                store.add(from: token)
                            }
                        } else {
                            if let first = filteredResults.first {
                                let surface = first.kanji.isEmpty ? first.reading : first.kanji
                                let firstGloss = first.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? first.gloss
                                let t = ParsedToken(surface: surface, reading: first.reading, meaning: firstGloss)
                                store.add(from: t)
                            } else {
                                store.add(from: token)
                            }
                        }
                    }
                )
            }
            .navigationDestination(isPresented: $goExtract) {
                ExtractWordsView(text: inputText)
            }
            .navigationTitle(currentNote != nil ? (currentNote!.title ?? "Note") : "")
            .navigationBarTitleDisplayMode(currentNote != nil ? .inline : .automatic)
            .onAppear {
                if let note = router.noteToOpen {
                    currentNote = note
                    inputText = note.text
                    isEditing = true
                    showFurigana = false
                    router.noteToOpen = nil
                }
                if !hasInitialized {
                    if inputText.isEmpty {
                        // Default to edit mode when starting with empty paste area
                        isEditing = true
                    }
                    hasInitialized = true
                }
                ingestSharedInbox()
                NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                    ingestSharedInbox()
                }
            }
            .onDisappear {
                NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
                lookupTask?.cancel()
            }
            .onChange(of: inputText) { _, newValue in
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
            .onChange(of: isEditing) { _, nowEditing in
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
                let surfaceMatch = hasKanji ? ((e.kanji.isEmpty ? e.reading : e.kanji) == t.surface ? 1 : 0)
                                            : 0
                let readingMatch = (!hasKanji ? (e.reading == (t.reading.isEmpty ? t.surface : t.reading) ? 1 : 0) : 0)
                let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
                let glossLength = firstGloss.count
                // Sort keys: common desc, surfaceMatch desc, readingMatch desc, glossLength asc
                return (common, surfaceMatch, readingMatch, -glossLength)
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
                baseFontSize: textSize,
                rubyFontSize: furiganaSize,
                lineSpacing: lineSpacing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(isEditing ? Color(UIColor.secondarySystemBackground) : Color.clear)
            .environment(\.furiganaGap, furiganaGap)
            .environment(\.highlightedToken, highlightedToken)
            .id(viewKey)
            .cornerRadius(12)
            .padding(.horizontal)
            .frame(maxHeight: .infinity)
            .onChange(of: textSize) { _, _ in bumpKey() }
            .onChange(of: furiganaSize) { _, _ in bumpKey() }
            .onChange(of: lineSpacing) { _, _ in bumpKey() }
            .onChange(of: furiganaGap) { _, _ in bumpKey() }
            .onChange(of: showFurigana) { _, _ in bumpKey() }
            .onChange(of: isEditing) { _, _ in bumpKey() }
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
                        let kana = token.reading.isEmpty ? token.surface : token.reading
                        return dictResults.filter { $0.reading == kana }
                    } else {
                        return dictResults
                    }
                }()

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

                    let entry = filteredResults.first
                    let displayKanji: String = {
                        if !hasKanjiInToken {
                            return token.reading.isEmpty ? token.surface : token.reading
                        }
                        if let e = entry {
                            return e.kanji.isEmpty ? e.reading : e.kanji
                        }
                        return token.surface
                    }()
                    let displayKana = entry?.reading ?? token.reading

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
                let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
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

// Re-open PasteView to keep type scope intact if needed
extension PasteView {}



