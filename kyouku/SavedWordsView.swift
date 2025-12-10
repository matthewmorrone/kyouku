//
//  SavedWordsView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI

struct SavedWordsView: View {
    @EnvironmentObject var store: WordStore
    @State private var searchText: String = ""
    @StateObject private var vm = DictionaryLookupViewModel()
    @State private var showingDefinition = false
    @State private var selectedWord: Word? = nil
    @State private var dictEntry: DictionaryEntry? = nil
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        NavigationStack {
            List {
                Section("Dictionary") {
                    if searchText.isEmpty {
                        Text("Type to search the dictionary")
                            .foregroundStyle(.secondary)
                    } else if vm.isLoading {
                        HStack { ProgressView(); Text("Searching…") }
                    } else if let msg = vm.errorMessage {
                        Text(msg).foregroundStyle(.secondary)
                    } else if vm.results.isEmpty {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(vm.results) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                                        .font(.headline)
                                    let firstGloss = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
                                    Text(firstGloss)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { addFromEntry(entry) } label: {
                                    if store.words.contains(where: { ($0.surface == (entry.kanji.isEmpty ? entry.reading : entry.kanji)) && $0.reading == entry.reading }) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else {
                                        Image(systemName: "plus.circle").foregroundStyle(.tint)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(store.words.contains(where: { ($0.surface == (entry.kanji.isEmpty ? entry.reading : entry.kanji)) && $0.reading == entry.reading }))
                            }
                        }
                    }
                }
                Section("Saved Words") {
                    ForEach(store.words.sorted(by: { $0.createdAt > $1.createdAt })) { word in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(word.surface)
                                    .font(.title3)
                                Text("【\(word.reading)】")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            if !word.meaning.isEmpty {
                                Text(word.meaning)
                                    .font(.subheadline)
                            }
                            if let note = word.note, !note.isEmpty {
                                Text(note)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedWord = word
                            showingDefinition = true
                            Task { await lookup(for: word) }
                        }
                    }
                    .onDelete(perform: store.delete)
                }
            }
            .navigationTitle("Words")
            .toolbar {
                EditButton()
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search dictionary")
            .onChange(of: searchText) { t in
                // Cancel any in-flight search task
                searchTask?.cancel()
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    vm.results = []
                    vm.errorMessage = nil
                    return
                }
                // Debounce 350ms
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if Task.isCancelled { return }
                    await vm.load(term: trimmed)
                }
            }
            .sheet(isPresented: $showingDefinition) {
                if isLookingUp {
                    VStack(spacing: 12) {
                        ProgressView("Looking up…")
                        if let w = selectedWord {
                            Text("\(w.surface)【\(w.reading)】")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                } else if let msg = lookupError {
                    VStack(spacing: 10) {
                        HStack {
                            Button(action: { if let w = selectedWord { store.add(from: ParsedToken(surface: w.surface, reading: w.reading, meaning: w.meaning)) }; showingDefinition = false }) {
                                Image(systemName: "plus.circle.fill").font(.title3)
                            }
                            Spacer()
                            Button("Close") { showingDefinition = false }
                        }
                        .padding(.bottom, 8)

                        Text("Lookup failed")
                            .font(.headline)
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                } else if let entry = dictEntry {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button(action: { addFromEntry(entry); showingDefinition = false }) {
                                Image(systemName: "plus.circle.fill").font(.title3)
                            }
                            Spacer()
                            Button(action: { showingDefinition = false }) {
                                Image(systemName: "xmark.circle.fill").font(.title3)
                            }
                        }

                        Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                            .font(.title2).bold()
                        if !entry.reading.isEmpty {
                            Text(entry.reading)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        let firstGloss = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
                        Text(firstGloss)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .presentationDetents([.medium, .large])
                } else {
                    VStack { Text("No definition found")
                        Button("Close") { showingDefinition = false }
                    }
                    .padding()
                }
            }
        }
    }
    
    private func lookup(for word: Word) async {
        await MainActor.run {
            isLookingUp = true
            lookupError = nil
            dictEntry = nil
        }
        do {
            var rows = try await DictionarySQLiteStore.shared.lookup(term: word.surface, limit: 1)
            if rows.isEmpty && !word.reading.isEmpty {
                rows = try await DictionarySQLiteStore.shared.lookup(term: word.reading, limit: 1)
            }
            await MainActor.run {
                dictEntry = rows.first
                isLookingUp = false
            }
        } catch {
            await MainActor.run {
                lookupError = (error as? DictionarySQLiteError)?.description ?? error.localizedDescription
                isLookingUp = false
            }
        }
    }
    
    private func addFromEntry(_ entry: DictionaryEntry) {
        let surface = entry.kanji.isEmpty ? entry.reading : entry.kanji
        let reading = entry.reading
        let firstGloss = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
        let token = ParsedToken(surface: surface, reading: reading, meaning: firstGloss)
        store.add(from: token)
    }
}

