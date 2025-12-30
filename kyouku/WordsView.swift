import SwiftUI

struct WordsView: View {
    @EnvironmentObject var store: WordsStore
    @StateObject private var lookup = DictionaryLookupViewModel()
    @State private var searchText: String = ""
    @State private var editModeState: EditMode = .inactive
    @State private var selectedWordIDs: Set<Word.ID> = []
    @State private var showDeleteAllConfirmation = false

    var body: some View {
        NavigationStack {
            VStack {
                searchField
                List(selection: $selectedWordIDs) {
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
                .environment(\.editMode, $editModeState)
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canEditSavedWords {
                        Button {
                            editModeState = editModeState.isEditing ? .inactive : .active
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(editModeState.isEditing ? "Done" : "Edit")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if isEditing {
                        Button(role: .destructive) {
                            deleteSelection()
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                        .disabled(selectedWordIDs.isEmpty)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if isEditing && canEditSavedWords {
                        Button(role: .destructive) {
                            showDeleteAllConfirmation = true
                        } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                        .accessibilityLabel("Delete all saved entries")
                    }
                }
            }
        }
        .task(id: searchText) {
            await performLookup()
        }
        .onChange(of: editModeState) { oldValue, newValue in
            if newValue.isEditing == false {
                selectedWordIDs.removeAll()
            }
        }
        .onChange(of: trimmedSearchText) { untrimmed, trimmed in
            if trimmed.isEmpty == false {
                editModeState = .inactive
            }
        }
        .onReceive(store.$words) { words in
            let ids = Set(words.map { $0.id })
            selectedWordIDs.formIntersection(ids)
        }
        .confirmationDialog(
            "Delete all saved entries?",
            isPresented: $showDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                emptySavedWords()
            }
            Button("Cancel", role: .cancel) { }
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
                savedRow(word)
                    .tag(word.id)
            }
        }
    }

    private func savedRow(_ word: Word) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.delete(id: word.id)
            } label: {
                Label("Delete", systemImage: "trash")
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

    private var isEditing: Bool {
        editModeState.isEditing
    }

    private var canEditSavedWords: Bool {
        hasActiveSearch == false && store.words.isEmpty == false
    }

    private func toggleSelection(for word: Word) {
        if selectedWordIDs.contains(word.id) {
            selectedWordIDs.remove(word.id)
        } else {
            selectedWordIDs.insert(word.id)
        }
    }

    private func deleteSelection() {
        guard selectedWordIDs.isEmpty == false else { return }
        store.delete(ids: selectedWordIDs)
        selectedWordIDs.removeAll()
    }

    private func emptySavedWords() {
        store.deleteAll()
        selectedWordIDs.removeAll()
        editModeState = .inactive
    }
}

private extension EditMode {
    var isEditing: Bool {
        self != .inactive
    }
}
