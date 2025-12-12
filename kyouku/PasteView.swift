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
                

                FuriganaTextEditor(
                    text: $inputText,
                    showFurigana: showFurigana,
                    isEditable: isEditing,
                    allowTokenTap: showFurigana && !isEditing
                ) { token in
                    selectedToken = token
                    showingDefinition = true
                    Task {
                        await lookupDefinitions(for: token)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
                .background(Color(UIColor.secondarySystemBackground))
                .environment(\.furiganaGap, furiganaGap)
                .cornerRadius(0)
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
                
                HStack {
                    Spacer()
                    HStack(spacing: 28) {
                        // HIDE KEYBOARD
                        Button { hideKeyboard() } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.title2)
                        }
                        .buttonBorderShape(.roundedRectangle)
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
                        .buttonBorderShape(.roundedRectangle)
                        .accessibilityLabel("Paste")


                        // EXTRACT
                        Button {
                            goExtract = true
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right")
                                .font(.title2)
                        }
                        .buttonBorderShape(.roundedRectangle)
                        .accessibilityLabel("Words ->")


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
                        .buttonBorderShape(.roundedRectangle)
                        .accessibilityLabel("Save")


                        // EDIT MODE TOGGLE (on = Edit mode)
                        Toggle(isOn: $isEditing) {
                            if UIImage(systemName: "character.cursor.ibeam.ja") != nil {
                                Image(systemName: "character.cursor.ibeam.ja")
                            } else {
                                Image(systemName: "character.cursor.ibeam")
                            }
                        }
                        .toggleStyle(.button)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(.accentColor)
                        .font(.title2)
                        .accessibilityLabel("Edit mode")


                        // FURIGANA TOGGLE (independent)
                        Toggle(isOn: $showFurigana) {
                            Image(showFurigana ? Self.furiganaSymbolOn : Self.furiganaSymbolOff)
                        }
                        .toggleStyle(.button)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(.accentColor)
                        .font(.title2)
                        .accessibilityLabel("Show Furigana")

                        // CLEAR
                        Button { inputText = "" } label: {
                            Image(systemName: "trash")
                                .font(.title2)
                        }
                        .buttonBorderShape(.roundedRectangle)
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

    private var workflowCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workflow")
                .font(.headline)
            Text("1) Paste text  →  2) Save note  →  3) Choose words  →  4) View list  →  5) Study flashcards.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    goExtract = true
                } label: {
                    Label("Choose words", systemImage: "arrowshape.turn.up.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    router.selectedTab = .words
                } label: {
                    Label("Word list", systemImage: "book")
                }
                .buttonStyle(.bordered)

                Button {
                    router.selectedTab = .cards
                } label: {
                    Label("Flashcards", systemImage: "rectangle.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .padding(.horizontal)
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
