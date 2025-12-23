import SwiftUI

struct WordsView: View {
    @EnvironmentObject var store: WordsStore
    @StateObject private var lookup = DictionaryLookupViewModel()
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            VStack {
                searchField
                List {
                    if hasActiveSearch {
                        Section("Dictionary Results") {
                            dictionarySection
                        }
                    } else {
                        Section("Saved Entries") {
                            savedSection
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if hasActiveSearch == false, store.words.isEmpty == false {
                        EditButton()
                    }
                }
            }
        }
        .task(id: searchText) {
            await performLookup()
        }
    }

    private var searchField: some View {
        TextField("Search Japanese or English", text: $searchText)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
    }

    @ViewBuilder
    private var dictionarySection: some View {
        if lookup.isLoading {
            HStack() {
                ProgressView()
                Text("Searching …")
                    .foregroundStyle(.secondary)
            }
        } else if let error = lookup.errorMessage, error.isEmpty == false {
            Text(error)
                .foregroundStyle(.secondary)
        } else if lookup.results.isEmpty {
            Text("No matches found for \(trimmedSearchText).")
                .foregroundStyle(.secondary)
        } else {
            ForEach(lookup.results) { entry in
                VStack(alignment: .leading) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displaySurface(for: entry))
                            .font(.headline)
                        if let kana = entry.kana, kana.isEmpty == false, kana != entry.kanji {
                            Text(kana)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if entry.gloss.isEmpty == false {
                        Text(firstGloss(for: entry))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        add(entry: entry)
                    } label: {
                        Label("Save", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if store.words.isEmpty {
            Text("Saved entries appear here. Save a dictionary result to get started.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(sortedWords) { word in
                VStack(alignment: .leading) {
                    Text(word.surface)
                        .font(.headline)
                    if let kana = word.kana, kana.isEmpty == false, kana != word.surface {
                        Text(kana)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if word.meaning.isEmpty == false {
                        Text(word.meaning)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let current = sortedWords
                let ids: [UUID] = offsets.compactMap { index in
                    guard index < current.count else { return nil }
                    return current[index].id
                }
                store.delete(ids: Set(ids))
            }
        }
    }

    private var sortedWords: [Word] {
        store.words.sorted { $0.createdAt > $1.createdAt }
    }

    private func performLookup() async {
        await lookup.load(term: searchText)
    }

    private func add(entry: DictionaryEntry) {
        let surface = displaySurface(for: entry)
        let gloss = firstGloss(for: entry)
        store.add(surface: surface, kana: entry.kana, meaning: gloss)
    }

    private func displaySurface(for entry: DictionaryEntry) -> String {
        if entry.kanji.isEmpty {
            if let kana = entry.kana, kana.isEmpty == false {
                return kana
            }
            return trimmedSearchText
        }
        return entry.kanji
    }

    private func firstGloss(for entry: DictionaryEntry) -> String {
        entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveSearch: Bool {
        trimmedSearchText.isEmpty == false
    }
}
