import SwiftUI

struct ExtractWordsView: View {
    @EnvironmentObject var store: WordStore

    let text: String

    @State private var tokens: [ParsedToken] = []
    @State private var selectedToken: ParsedToken? = nil
    @State private var showingDefinition = false

    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil

    var body: some View {
        List {
            ForEach(tokens) { token in
                HStack(spacing: 12) {
                    FuriganaTextView(token: token)
                    Spacer()
                    Button {
                        if !store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
                            store.add(from: token)
                        }
                    } label: {
                        if store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.tint)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedToken = token
                    showingDefinition = true
                    Task { await lookupDefinitions(for: token) }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Extract Words")
        .onAppear {
            tokens = JapaneseParser.parse(text: text)
        }
        .sheet(isPresented: $showingDefinition) {
            if let token = selectedToken {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: {
                            if let token = selectedToken,
                               !store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
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

                    if isLookingUp {
                        ProgressView("Looking up definitions…")
                    } else if let err = lookupError {
                        Text(err).foregroundStyle(.secondary)
                    } else if let entry = dictResults.first {
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
                    } else {
                        Text("No definitions found.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .presentationDetents([.medium, .large])
            } else {
                Text("No selection").padding()
            }
        }
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
