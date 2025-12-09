//
//  SavedWordsView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI

struct SavedWordsView: View {
    @EnvironmentObject var store: WordStore
    @State private var showingDefinition = false
    @State private var selectedWord: Word? = nil
    @State private var dictEntry: DictionaryEntry? = nil
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil
    
    var body: some View {
        NavigationStack {
            List {
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
            .navigationTitle("Words")
            .toolbar {
                EditButton()
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
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                        Text("Lookup failed")
                            .font(.headline)
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Close") { showingDefinition = false }
                    }
                    .padding()
                } else if let entry = dictEntry {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                                    .font(.title3).bold()
                                if !entry.reading.isEmpty && entry.reading != entry.kanji {
                                    Text("【\(entry.reading)】")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            let firstGloss = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
                            Text(firstGloss)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                Button("Close") { showingDefinition = false }
                            }
                        }
                        .padding()
                    }
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
}
