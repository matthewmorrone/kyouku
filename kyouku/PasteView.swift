//
//  PasteView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI

struct PasteView: View {
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

    @AppStorage("readingTextSize") private var textSize: Double = 17
    @AppStorage("readingFuriganaSize") private var furiganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var lineSpacing: Double = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                HStack {
                    Spacer()
                    HStack(spacing: 28) {
                        // HIDE KEYBOARD
                        Button { hideKeyboard() } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.title2)
                        }

                        // PASTE
                        Button {
                            if let str = UIPasteboard.general.string {
                                inputText = str
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.title2)
                        }

                        // EXTRACT
                        Button {
                            goExtract = true
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right")
                                .font(.title2)
                        }

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

                        // FURIGANA TOGGLE
                        Button { showFurigana.toggle() } label: {
                            Image(systemName: showFurigana ? "textformat" : "textformat.size.smaller")
                                .font(.title2)
                        }

                        // CLEAR
                        Button { inputText = "" } label: {
                            Image(systemName: "trash")
                                .font(.title2)
                        }
                    }
                    Spacer()
                }

                FuriganaTextEditor(text: $inputText, showFurigana: showFurigana) { token in
                    selectedToken = token
                    showingDefinition = true
                    Task {
                        await lookupDefinitions(for: token)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(8)
                .padding(.horizontal)
                .frame(maxHeight: .infinity)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 24) }
            .sheet(isPresented: $showingDefinition) {
                if let token = selectedToken {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(action: {
                                if let first = dictResults.first {
                                    let surface = first.kanji.isEmpty ? first.reading : first.kanji
                                    let firstGloss = first.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? first.gloss
                                    let t = ParsedToken(surface: surface, reading: first.reading, meaning: firstGloss)
                                    store.add(from: t)
                                } else {
                                    store.add(from: token)
                                }
                                showingDefinition = false
                            }) {
                                Image(systemName: "plus.circle.fill").font(.title3)
                            }
                            Spacer()
                            Button(action: { showingDefinition = false }) {
                                Image(systemName: "xmark.circle.fill").font(.title3)
                            }
                        }

                        // Determine display values from entry if available, else token
                        let entry = dictResults.first
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
                        } else if let e = entry {
                            let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
                            Text(firstGloss)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No definitions found.")
                                .foregroundStyle(.secondary)
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
            }
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func lookupDefinitions(for token: ParsedToken) async {
        await MainActor.run {
            isLookingUp = true
            lookupError = nil
            dictResults = []
        }
        do {
            var results = try await DictionarySQLiteStore.shared.lookup(term: token.surface, limit: 1)
            if results.isEmpty && !token.reading.isEmpty {
                let alt = try await DictionarySQLiteStore.shared.lookup(term: token.reading, limit: 1)
                if !alt.isEmpty { results = alt }
            }
            await MainActor.run {
                dictResults = results
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

