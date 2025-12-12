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
                    onTokenTap: { token in
                        selectedToken = token
                        showingDefinition = true
                        Task { await lookupDefinitions(for: token) }
                    }
                )
                
                HStack {
                    Spacer()
                    HStack(alignment: .center, spacing: 8) {
                        Button { hideKeyboard() } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.horizontal, 1)
                        .accessibilityLabel("Hide keyboard")

                        // PASTE
                        Button {
                            if let str = UIPasteboard.general.string {
                                inputText = str
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.horizontal, 1)
                        .accessibilityLabel("Paste")


                        // EXTRACT
                        Button {
                            goExtract = true
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.horizontal, 1)
                        .accessibilityLabel("Extract Words")

                        // SAVE NOTE
                        Button {
                            guard !inputText.isEmpty else { return }
                            if let existing = currentNote {
                                // Update existing note's text, keep its title and createdAt
                                notes.notes = notes.notes.map { n in
                                    if n.id == existing.id {
                                        return Note(id: n.id, title: n.title, text: inputText, createdAt: n.createdAt)
                                    } else {
                                        return n
                                    }
                                }
                                notes.save()
                            } else {
                                // Create new note and set as current
                                let firstLine = inputText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
                                let title = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines)
                                notes.addNote(title: (title?.isEmpty == true) ? nil : title, text: inputText)
                                currentNote = notes.notes.first
                            }
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.horizontal, 1)
                        .accessibilityLabel("Save")

                        Toggle(isOn: $isEditing) {
                            if UIImage(systemName: "character.cursor.ibeam.ja") != nil {
                                Image(systemName: "character.cursor.ibeam.ja")
                            } else {
                                Image(systemName: "character.cursor.ibeam")
                            }
                        }
                        .toggleStyle(.button)
                        .tint(.accentColor)
                        .font(.title2)
                        .controlSize(.regular)
                        .padding(.horizontal, 1)
                        .accessibilityLabel("Edit mode")

                        Toggle(isOn: $showFurigana) {
                            Image(showFurigana ? Self.furiganaSymbolOn : Self.furiganaSymbolOff)
                        }
                        .toggleStyle(.button)
                        .tint(.accentColor)
                        .font(.title2)
                        .controlSize(.regular)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("Show Furigana")

                        Button { inputText = "" } label: {
                            Image(systemName: "trash")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("Clear")

                    }
                    Spacer()
                }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 24) }
            .sheet(isPresented: $showingDefinition) {
                if let token = selectedToken {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(action: {
                                if let idx = selectedEntryIndex, dictResults.indices.contains(idx) {
                                    let e = dictResults[idx]
                                    let surface = e.kanji.isEmpty ? e.reading : e.kanji
                                    let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
                                    let t = ParsedToken(surface: surface, reading: e.reading, meaning: firstGloss)
                                    store.add(from: t)
                                } else if let first = dictResults.first {
                                    let surface = first.kanji.isEmpty ? first.reading : first.kanji
                                    let firstGloss = first.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? first.gloss
                                    let t = ParsedToken(surface: surface, reading: first.reading, meaning: firstGloss)
                                    store.add(from: t)
                                } else {
                                    store.add(from: token)
                                }
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

                        // Determine display values from selected entry if available, else token
                        let displayIndex = selectedEntryIndex ?? 0
                        let entry = dictResults.indices.contains(displayIndex) ? dictResults[displayIndex] : dictResults.first
                        let displayKanji = entry.map { $0.kanji.isEmpty ? $0.reading : $0.kanji } ?? token.surface
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
                        } else if dictResults.isEmpty {
                            Text("No definitions found.")
                                .foregroundStyle(.secondary)
                        } else {
                            // Show a few definitions with option to view more
                            let maxShown = showAllDefinitions ? dictResults.count : min(3, dictResults.count)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(0..<maxShown, id: \.self) { idx in
                                    let e = dictResults[idx]
                                    let title = e.kanji.isEmpty ? e.reading : e.kanji
                                    let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
                                    Button(action: { selectedEntryIndex = idx }) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Image(systemName: selectedEntryIndex == idx ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(selectedEntryIndex == idx ? Color.accentColor : .secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(title).font(.body)
                                                Text(firstGloss).font(.callout).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                                if dictResults.count > 3 {
                                    Button(showAllDefinitions ? "Show fewer" : "View more") {
                                        showAllDefinitions.toggle()
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                    .padding()
                    .presentationDetents([.fraction(0.33)])
                    .presentationDragIndicator(.visible)
                } else {
                    Text("No selection").padding()
                }
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
            }
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
        await MainActor.run {
            isLookingUp = true
            lookupError = nil
            dictResults = []
            selectedEntryIndex = nil
            showAllDefinitions = false
        }
        do {
            let rawSurface = token.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawReading = token.reading.trimmingCharacters(in: .whitespacesAndNewlines)

            // Basic sanitation: remove trailing punctuation that often appears in tokenization
            let sanitizedSurface = rawSurface.trimmingCharacters(in: CharacterSet(charactersIn: "。、，,.!？?；;：:"))
            let sanitizedReading = rawReading.trimmingCharacters(in: CharacterSet(charactersIn: "。、，,.!？?；;：:"))

            // Try multiple queries, prefer surface, then reading, then sanitized variants
            var all: [DictionaryEntry] = []
            let limit = 10

            func appendUnique(_ new: [DictionaryEntry]) {
                for n in new {
                    if !all.contains(where: { $0.kanji == n.kanji && $0.reading == n.reading && $0.gloss == n.gloss }) {
                        all.append(n)
                    }
                }
            }

            let q1 = try await DictionarySQLiteStore.shared.lookup(term: rawSurface, limit: limit)
            appendUnique(q1)

            if all.isEmpty && !rawReading.isEmpty {
                let q2 = try await DictionarySQLiteStore.shared.lookup(term: rawReading, limit: limit)
                appendUnique(q2)
            }

            if all.isEmpty && sanitizedSurface != rawSurface {
                let q3 = try await DictionarySQLiteStore.shared.lookup(term: sanitizedSurface, limit: limit)
                appendUnique(q3)
            }

            if all.isEmpty && !sanitizedReading.isEmpty && sanitizedReading != rawReading {
                let q4 = try await DictionarySQLiteStore.shared.lookup(term: sanitizedReading, limit: limit)
                appendUnique(q4)
            }

            await MainActor.run {
                dictResults = all
                isLookingUp = false
            }
        } catch {
            await MainActor.run {
                lookupError = (error as? DictionarySQLiteError)?.description ?? error.localizedDescription
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
            .background(Color(UIColor.secondarySystemBackground))
            .environment(\.furiganaGap, furiganaGap)
            .id(viewKey)
            .cornerRadius(0)
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

private struct FuriganaGapKey: EnvironmentKey {
    static let defaultValue: Double = 2
}

extension EnvironmentValues {
    var furiganaGap: Double {
        get { self[FuriganaGapKey.self] }
        set { self[FuriganaGapKey.self] = newValue }
    }
}

// Re-open PasteView to keep type scope intact if needed
extension PasteView {}


