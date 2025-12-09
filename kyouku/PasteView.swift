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

    @State private var inputText: String = ""

    @State private var showFurigana: Bool = false
    @State private var selectedToken: ParsedToken? = nil
    @State private var showingDefinition = false
    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil

    @AppStorage("readingTextSize") private var textSize: Double = 17
    @AppStorage("readingFuriganaSize") private var furiganaSize: Double = 9
    @AppStorage("readingLineSpacing") private var lineSpacing: Double = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                // TOP BAR: Paste + Save icons
                HStack(spacing: 24) {

                    // PASTE BUTTON
                    Button {
                        if let str = UIPasteboard.general.string {
                            inputText = str
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.title2)
                    }

                    // SAVE NOTE BUTTON
                    Button {
                        guard !inputText.isEmpty else { return }
                        let firstLine = inputText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
                        let title = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines)
                        notes.addNote(title: (title?.isEmpty == true) ? nil : title, text: inputText)
                        // Do not clear inputText; keep the textarea content
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title2)
                    }
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
            .navigationTitle("Paste")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        hideKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFurigana.toggle()
                    } label: {
                        Image(systemName: showFurigana ? "textformat" : "textformat.size.smaller")
                    }
                }
            }
            .sheet(isPresented: $showingDefinition) {
                if let token = selectedToken {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(token.surface)
                            .font(.title2).bold()
                        if !token.reading.isEmpty {
                            Text("Reading: \(token.reading)")
                                .font(.headline)
                        }
                        if isLookingUp {
                            ProgressView("Looking up definitions…")
                        } else if let err = lookupError {
                            Text(err).foregroundStyle(.secondary)
                        } else if dictResults.isEmpty {
                            Text("No definitions found.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(dictResults, id: \.id) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                                            .font(.headline)
                                        if !entry.reading.isEmpty && entry.reading != entry.kanji {
                                            Text("【\(entry.reading)】")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(entry.gloss)
                                        .font(.body)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        HStack {
                            if let token = selectedToken {
                                Button("Add to Words") {
                                    if !store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
                                        store.add(from: token)
                                    }
                                    showingDefinition = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            Spacer()
                            Button("Close") { showingDefinition = false }
                        }
                    }
                    .padding()
                    .presentationDetents([.medium, .large])
                } else {
                    Text("No selection").padding()
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
            var results = try await DictionarySQLiteStore.shared.lookup(term: token.surface)
            if results.isEmpty && !token.reading.isEmpty {
                let alt = try await DictionarySQLiteStore.shared.lookup(term: token.reading)
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
