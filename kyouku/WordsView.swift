import SwiftUI

struct WordsView: View {
    @EnvironmentObject var store: WordsStore
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var router: AppRouter
    @StateObject private var lookup = DictionaryLookupViewModel()
    @ObservedObject private var viewedHistory = ViewedDictionaryHistoryStore.shared
    @State private var searchText: String = ""
    @State private var searchMode: DictionarySearchMode = .japanese
    @State private var editModeState: EditMode = .inactive
    @State private var selectedWordIDs: Set<Word.ID> = []
    @State private var showCSVImportSheet = false
    @State private var selectedFilter: WordsListFilter = .all
    @State private var showListsSheet: Bool = false
    @State private var showListsBrowserSheet: Bool = false
    @State private var showNewWordSheet: Bool = false
    @AppStorage("wordsShowEntrySourceLabels") private var showEntrySourceLabels: Bool = false
    @AppStorage("dictionaryHomeShelf") private var dictionaryHomeShelfRaw: String = DictionaryHomeShelf.favorites.rawValue
    @State private var suppressedSearchTaskID: String? = nil
    @State private var cachedSortedWords: [Word] = []
    @State private var cachedNoteListItems: [NoteListItem] = []
    @State private var cachedListCounts: [UUID: Int] = [:]
    @State private var listNamesByID: [UUID: String] = [:]
    @State private var noteTitlesByID: [UUID: String] = [:]
    @State private var savedSurfaceKeys: Set<String> = []
    @State private var savedSurfaceKanaKeys: Set<SurfaceKanaKey> = []

    @State private var isPromptingForBulkAddListName: Bool = false
    @State private var pendingBulkAddListName: String = ""

    @State private var editingWord: EditingWord? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                if hasActiveSearch == false {
                    dictionaryHomeToggle
                }
                mainList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.editMode, $editModeState)
            .listStyle(.plain)
            .navigationTitle("Words")
            .onAppear {
                refreshListCaches()
                refreshSortedWords()
                refreshSavedWordCaches()
            }
            .onChange(of: selectedFilter) { _, _ in
                refreshSortedWords()
            }
            .onReceive(store.$words) { _ in
                refreshSortedWords()
                refreshNoteListItems()
                refreshListCounts()
                refreshSavedWordCaches()
            }
            .onReceive(store.$lists) { _ in
                refreshListNameCache()
                refreshListCounts()
            }
            .onReceive(notesStore.$notes) { _ in
                refreshNoteTitleCache()
                refreshNoteListItems()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showCSVImportSheet = true
                    } label: {
                        Label("Import CSV", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityLabel("Import CSV")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showNewWordSheet = true
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .accessibilityLabel("New Word")
                    .disabled(isEditing)

                    Menu {
                        Section("View") {
                            Toggle(isOn: $showEntrySourceLabels) {
                                Label("Show Source", systemImage: "tag")
                            }
                        }

                        if dictionaryHomeShelf == .favorites {
                            Section("Filter") {
                                Button {
                                    selectedFilter = .all
                                } label: {
                                    HStack {
                                        Text("All Words")
                                        if selectedFilter.isAll {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                Section("Lists") {
                                    if store.lists.isEmpty == false {
                                        Divider()
                                        ForEach(store.lists) { list in
                                            Button {
                                                selectedFilter = .list(list.id)
                                            } label: {
                                                HStack {
                                                    Text(list.name)
                                                    Spacer()
                                                    Text("\(cachedListCounts[list.id] ?? 0)")
                                                        .foregroundStyle(.secondary)
                                                    if selectedFilter == .list(list.id) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                Section("Notes") {
                                    if cachedNoteListItems.isEmpty == false {
                                        Divider()
                                        ForEach(cachedNoteListItems) { item in
                                            Button {
                                                selectedFilter = .note(item.id)
                                            } label: {
                                                HStack {
                                                    Text(item.title)
                                                    Spacer()
                                                    Text("\(item.count)")
                                                        .foregroundStyle(.secondary)
                                                    if selectedFilter == .note(item.id) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            Button {
                                showListsBrowserSheet = true
                            } label: {
                                Label("Open Lists…", systemImage: "folder")
                            }
                            Button {
                                showListsSheet = true
                            } label: {
                                Label("Manage Lists…", systemImage: "folder.badge.gear")
                            }
                            /* Section("Lists") {
                                Menu {

                                } label: {
                                    Label("Lists…", systemImage: "folder")
                                }
                            } */
                        } else {
                            Section("History") {
                                Button(role: .destructive) {
                                    viewedHistory.clear()
                                } label: {
                                    Label("Clear Viewed History", systemImage: "trash")
                                }
                                .disabled(viewedHistory.items.isEmpty)
                            }
                        }
                    } label: {
                        Label(
                            dictionaryHomeShelf == .favorites ? "Filters" : "More",
                            systemImage: dictionaryHomeShelf == .favorites
                                ? (selectedFilter.isAll ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                : "ellipsis.circle"
                        )
                    }
                    .accessibilityLabel(dictionaryHomeShelf == .favorites ? "Filter lists" : "History options")

                    if isEditing {
                        if canEditSavedWords {
                            Button {
                                selectAllSavedWords()
                            } label: {
                                Label("Select All", systemImage: "checkmark.circle")
                            }
                            .accessibilityLabel("Select all saved entries")

                            Menu {
                                if store.lists.isEmpty {
                                    Button {
                                        promptForNewListName()
                                    } label: {
                                        Label("Create New List…", systemImage: "plus")
                                    }
                                } else {
                                    ForEach(store.lists) { list in
                                        Button {
                                            addSelection(toList: list.id)
                                        } label: {
                                            Text(list.name)
                                        }
                                    }
                                    Divider()
                                    Button {
                                        promptForNewListName()
                                    } label: {
                                        Label("Create New List…", systemImage: "plus")
                                    }
                                }
                            } label: {
                                Label("Add to List", systemImage: "text.badge.plus")
                            }
                            .accessibilityLabel("Add selected entries to list")
                            .disabled(selectedWordIDs.isEmpty)
                        }
                        Button(role: .destructive) {
                            deleteSelection()
                        } label: {
                            Label("Delete Selected", systemImage: "trash")
                        }
                        .disabled(selectedWordIDs.isEmpty)
                    }
                    if canEditSavedWords {
                        Button {
                            editModeState = editModeState.isEditing ? .inactive : .active
                        }
                        label: {
                            Text(editModeState.isEditing ? "Done" : "Edit")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel(editModeState.isEditing ? "Done" : "Edit")
                    }
                }
            }
        }
        .appThemedRoot()
        .task(id: searchTaskID) {
            await performLookup()
        }
        .onChange(of: editModeState) { oldValue, newValue in
            if newValue.isEditing == false {
                selectedWordIDs.removeAll()
            }
        }
        .onChange(of: selectedFilter) { oldValue, newValue in
            if oldValue != newValue {
                selectedWordIDs.removeAll()
                editModeState = .inactive
            }
        }
        .onChange(of: dictionaryHomeShelfRaw) { oldValue, newValue in
            if oldValue != newValue {
                selectedWordIDs.removeAll()
                editModeState = .inactive
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
        .sheet(isPresented: $showCSVImportSheet) {
            NavigationStack {
                WordsCSVImportView()
            }
        }
        .sheet(isPresented: $showListsSheet) {
            NavigationStack {
                WordListsManagerView()
            }
        }
        .sheet(isPresented: $showListsBrowserSheet) {
            NavigationStack {
                WordListsBrowserView(selectedFilter: $selectedFilter)
            }
        }
        .sheet(isPresented: $showNewWordSheet) {
            WordCreateView(initialSurface: hasActiveSearch ? trimmedSearchText : "")
        }
        .sheet(
            isPresented: Binding(
                get: { editingWord != nil },
                set: { isPresented in
                    if isPresented == false {
                        editingWord = nil
                    }
                }
            )
        ) {
            Group {
                if let item = editingWord {
                    WordEditView(wordID: item.id)
                }
            }
        }
        .sheet(
            item: Binding(
                get: { router.openWordRequest },
                set: { newValue in
                    // Only allow dismissal from the sheet side.
                    if newValue == nil {
                        router.openWordRequest = nil
                    }
                }
            )
        ) { request in
            NavigationStack {
                if let word = store.word(id: request.wordID) {
                    WordDefinitionView(
                        request: .init(
                            term: .init(surface: word.dictionarySurface ?? displayHeadword(for: word), kana: word.kana),
                            context: .init(sentence: nil, lemmaCandidates: [], tokenPartOfSpeech: nil, tokenParts: []),
                            metadata: .init(sourceNoteID: word.sourceNoteIDs.sorted { $0.uuidString < $1.uuidString }.first)
                        )
                    )
                } else {
                    Text("Word not found")
                        .foregroundStyle(.secondary)
                        .navigationTitle("Word")
                }
            }
            .appThemedRoot()
        }
        .alert("New List", isPresented: $isPromptingForBulkAddListName) {
            TextField("List name", text: $pendingBulkAddListName)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)

            Button("Cancel", role: .cancel) {
                pendingBulkAddListName = ""
            }

            Button("Save") {
                createListAndAddSelection()
            }
            .disabled(pendingBulkAddListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for the new list.")
        }
    }

    private var searchBar: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                TextField("Search Japanese or English", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .padding(.leading, 12)
                    .padding(.trailing, searchText.isEmpty ? 12 : 34)
                    .padding(.vertical, 10)

                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                Circle()
                                    .fill(Color(uiColor: .tertiarySystemFill))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .accessibilityLabel("Clear search")
                }
            }

            Divider()
                .frame(height: 28)
                .background(Color(uiColor: .separator))
                .padding(.vertical, 6)

            Picker("Search language", selection: $searchMode) {
                Text("JP").tag(DictionarySearchMode.japanese)
                Text("EN").tag(DictionarySearchMode.english)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            .padding(.horizontal, 8)
            .accessibilityLabel("Search language")
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appBorder, lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var mainList: some View {
        if hasActiveSearch {
            List {
                dictionarySection
            }
            .appThemedScrollBackground()
        } else {
            if dictionaryHomeShelf == .favorites {
                List(selection: $selectedWordIDs) {
                    savedSection
                }
                .appThemedScrollBackground()
            } else {
                List {
                    historySection
                }
                .appThemedScrollBackground()
            }
        }
    }

    private var dictionaryHomeShelf: DictionaryHomeShelf {
        DictionaryHomeShelf(rawValue: dictionaryHomeShelfRaw) ?? .favorites
    }

    private var dictionaryHomeShelfSelection: Binding<DictionaryHomeShelf> {
        Binding(
            get: { dictionaryHomeShelf },
            set: { dictionaryHomeShelfRaw = $0.rawValue }
        )
    }

    private var dictionaryHomeToggle: some View {
        Picker("Dictionary", selection: dictionaryHomeShelfSelection) {
            ForEach(DictionaryHomeShelf.allCases) { shelf in
                Text(shelf.title).tag(shelf)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var dictionarySection: some View {
        if lookup.isLoading {
            HStack() {
                ProgressView()
                Text("Searching …")
                    .foregroundStyle(Color.appTextSecondary)
            }
        } else if let error = lookup.errorMessage, error.isEmpty == false {
            Text(error)
                .foregroundStyle(Color.appTextSecondary)
        } else if lookup.results.isEmpty {
            Text("No matches found for \(trimmedSearchText).")
                .foregroundStyle(Color.appTextSecondary)
        } else {
            ForEach(mergedLookupResults) { row in
                NavigationLink {
                    WordDefinitionView(
                        request: .init(
                            term: .init(surface: row.surface, kana: row.kana),
                            context: .init(sentence: nil, lemmaCandidates: [], tokenPartOfSpeech: nil, tokenParts: []),
                            metadata: .init(sourceNoteID: nil)
                        )
                    )
                } label: {
                    dictionaryRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        if store.words.isEmpty {
            Text("Saved entries appear here. Save a dictionary result to get started.")
                .foregroundStyle(Color.appTextSecondary)
        } else {
            let wordsToRender = cachedSortedWords.isEmpty ? store.words : cachedSortedWords
            ForEach(wordsToRender) { word in
                if isEditing {
                    savedRow(word)
                        .tag(word.id)
                } else {
                    NavigationLink {
                        WordDefinitionView(
                            request: .init(
                                term: .init(surface: word.dictionarySurface ?? displayHeadword(for: word), kana: word.kana),
                                context: .init(sentence: nil, lemmaCandidates: [], tokenPartOfSpeech: nil, tokenParts: []),
                                metadata: .init(sourceNoteID: word.sourceNoteIDs.sorted { $0.uuidString < $1.uuidString }.first)
                            )
                        )
                    } label: {
                        savedRow(word)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if viewedHistory.items.isEmpty {
            Text("Words you view in Details appear here.")
                .foregroundStyle(Color.appTextSecondary)
        } else {
            ForEach(viewedHistory.items) { item in
                NavigationLink {
                    WordDefinitionView(
                        request: .init(
                            term: .init(surface: item.surface, kana: item.kana),
                            context: .init(sentence: nil, lemmaCandidates: [], tokenPartOfSpeech: nil, tokenParts: []),
                            metadata: .init(sourceNoteID: nil)
                        )
                    )
                } label: {
                    WordsHistoryRowView(item: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        viewedHistory.remove(id: item.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func savedRow(_ word: Word) -> some View {
        let headword = displayHeadword(for: word)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headword)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let kana = word.kana, kana.isEmpty == false, kana != headword {
                    Text(kana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if word.meaning.isEmpty == false {
                    Text(word.meaning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if showEntrySourceLabels, let sourceLabel = entrySourceLabel(for: word) {
                Text(sourceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Source: \(sourceLabel)")
            } else if word.sourceNoteIDs.isEmpty == false {
                Image(systemName: "note.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("From note")
            }
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.delete(id: word.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                editingWord = EditingWord(id: word.id)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(Color(uiColor: .systemBlue))
        }
    }

    private func dictionaryRow(_ row: DictionaryResultRow) -> some View {
        let isSaved = isMergedRowAlreadySaved(row)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.surface)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let kana = row.kana, kana.isEmpty == false, kana != row.surface {
                    Text(kana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if row.gloss.isEmpty == false {
                    Text(row.gloss)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Button {
                toggleMergedRow(row)
            } label: {
                Image(systemName: isSaved ? "bookmark.circle.fill" : "bookmark.circle")
                    .font(.headline)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless)
            .tint(isSaved ? .accentColor : .secondary)
            .accessibilityLabel(isSaved ? "Remove from saved" : "Save")
        }
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func refreshSortedWords() {
        let base = store.words
        let filtered: [Word]
        switch selectedFilter {
        case .all:
            filtered = base
        case .list(let listID):
            filtered = base.filter { $0.listIDs.contains(listID) }
        case .note(let noteID):
            filtered = base.filter { $0.sourceNoteIDs.contains(noteID) }
        }
        cachedSortedWords = filtered.sorted { $0.createdAt > $1.createdAt }
    }

    private func entrySourceLabel(for word: Word) -> String? {
        var components: [String] = []

        if word.sourceNoteIDs.isEmpty == false {
            let sorted = word.sourceNoteIDs
                .filter { noteTitlesByID[$0] != nil }
                .sorted { $0.uuidString < $1.uuidString }
            guard sorted.isEmpty == false else {
                // If we somehow have stale IDs, just omit the note label.
                // (WordsStore also prunes these on notes changes.)
                return components.isEmpty ? nil : components.joined(separator: " · ")
            }
            let first = sorted[0]
            let title = title(forNoteID: first) ?? ""
            if sorted.count == 1 {
                components.append(title)
            } else {
                components.append("\(title) +\(sorted.count - 1)")
            }
        }

        let listIDs = word.listIDs
        if listIDs.isEmpty == false {
            let names = listIDs
                .compactMap { name(forListID: $0) }
                .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }

            if let first = names.first {
                if names.count == 1 {
                    components.append(first)
                } else {
                    components.append("\(first) +\(names.count - 1)")
                }
            } else {
                components.append("List")
            }
        }

        let combined = components.joined(separator: " · ")
        return combined.isEmpty ? nil : combined
    }

    private func name(forListID id: UUID) -> String? {
        listNamesByID[id]
    }

    private func title(forNoteID id: UUID) -> String? {
        noteTitlesByID[id]
    }

    private struct NoteListItem: Identifiable, Hashable {
        let id: UUID
        let title: String
        let count: Int
    }

    private func refreshNoteListItems() {
        let entries = buildSortedNoteCountEntries(from: store.words, titleFor: title(forNoteID:))
        cachedNoteListItems = entries.map { entry in
            NoteListItem(id: entry.noteID, title: entry.title, count: entry.count)
        }
    }

    private func refreshListNameCache() {
        var names: [UUID: String] = [:]
        names.reserveCapacity(store.lists.count)
        for list in store.lists {
            names[list.id] = list.name
        }
        listNamesByID = names
    }

    private func refreshListCounts() {
        var counts: [UUID: Int] = [:]
        for word in store.words {
            for listID in word.listIDs {
                counts[listID, default: 0] += 1
            }
        }
        cachedListCounts = counts
    }

    private func refreshNoteTitleCache() {
        noteTitlesByID = buildNoteTitlesByID(from: notesStore.notes, maxDerivedTitleLength: 42)
    }

    private func refreshListCaches() {
        refreshListNameCache()
        refreshListCounts()
        refreshNoteTitleCache()
        refreshNoteListItems()
    }

    private func refreshSavedWordCaches() {
        var surfaceKeys: Set<String> = []
        var surfaceKanaKeys: Set<SurfaceKanaKey> = []
        surfaceKeys.reserveCapacity(store.words.count)
        surfaceKanaKeys.reserveCapacity(store.words.count)
        for word in store.words {
            let surfaceKey = kanaFoldToHiragana(word.surface)
            surfaceKeys.insert(surfaceKey)
            let kanaKey = kanaFoldToHiragana(word.kana ?? "")
            surfaceKanaKeys.insert(SurfaceKanaKey(surface: surfaceKey, kana: kanaKey))
        }
        savedSurfaceKeys = surfaceKeys
        savedSurfaceKanaKeys = surfaceKanaKeys
    }

    private func performLookup() async {
        // If we programmatically change `searchMode` after a successful fallback
        // lookup, SwiftUI will re-run the `.task(id:)`. Suppress that second run
        // to avoid hitting SQLite twice for the same term.
        if let suppressed = suppressedSearchTaskID {
            if suppressed == searchTaskID {
                suppressedSearchTaskID = nil
                return
            } else {
                // Stale suppression key; clear it so it can't affect future searches.
                suppressedSearchTaskID = nil
            }
        }

        let term = trimmedSearchText

        // If the user cleared the search, reset results immediately
        // without waiting for the debounce delay.
        if term.isEmpty {
            await lookup.load(term: "", mode: searchMode)
            return
        }

        // Debounce rapid typing so we don't hit SQLite on every keystroke.
        // The surrounding `.task(id:)` cancels this work when the search
        // text changes again, so only the final pause triggers a lookup.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
        if Task.isCancelled { return }

        let initialMode = searchMode
        await lookup.load(term: term, mode: initialMode)
        if Task.isCancelled { return }

        // If this mode returned zero results, try the other mode.
        // Only switch the UI mode if it actually produces results.
        if lookup.results.isEmpty {
            let fallbackMode: DictionarySearchMode = (initialMode == .english) ? .japanese : .english
            await lookup.load(term: term, mode: fallbackMode)
            if Task.isCancelled { return }

            if lookup.results.isEmpty == false {
                suppressedSearchTaskID = makeSearchTaskID(mode: fallbackMode, term: term)
                searchMode = fallbackMode
            }
        }
    }

    private func isMergedRowAlreadySaved(_ row: DictionaryResultRow) -> Bool {
        let surface = row.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = row.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasSavedWord(surface: surface, reading: reading)
    }

    private func toggleMergedRow(_ row: DictionaryResultRow) {
        let surface = row.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = row.kana?.trimmingCharacters(in: .whitespacesAndNewlines)

        func matchesSavedKey(_ word: Word) -> Bool {
            guard kanaFoldToHiragana(word.surface) == kanaFoldToHiragana(surface) else { return false }
            // If we don't know the reading for this result, treat reading as a wildcard
            // so the star can still toggle.
            if let reading {
                let foldedReading = kanaFoldToHiragana(reading)
                return kanaFoldToHiragana(word.kana ?? "") == foldedReading
            }
            return true
        }

        if isMergedRowAlreadySaved(row) {
            let matches = store.words.filter(matchesSavedKey)
            let ids = Set(matches.map { $0.id })
            if ids.isEmpty == false {
                store.delete(ids: ids)
            }
            return
        }

        let meaning = row.gloss.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.isEmpty == false, meaning.isEmpty == false else { return }
        store.add(surface: surface, kana: reading, meaning: meaning)
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

    private func displayHeadword(for word: Word) -> String {
        let surface = word.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = word.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (kana?.isEmpty == false) ? kana : nil

        guard let noteID = word.sourceNoteIDs.sorted(by: { $0.uuidString < $1.uuidString }).first else {
            return surface
        }
        guard let noteText = notesStore.notes.first(where: { $0.id == noteID })?.text, noteText.isEmpty == false else {
            return surface
        }

        // Prefer whatever appears in the note verbatim.
        if surface.isEmpty == false, noteText.contains(surface) {
            return surface
        }
        if let normalizedKana, noteContains(noteText, candidate: normalizedKana) {
            return normalizedKana
        }
        return surface
    }

    private func noteContains(_ noteText: String, candidate: String) -> Bool {
        if noteText.contains(candidate) { return true }
        let foldedNote = kanaFoldToHiragana(noteText)
        let foldedCandidate = kanaFoldToHiragana(candidate)
        return foldedNote.contains(foldedCandidate)
    }

    private func kanaFoldToHiragana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    private func firstGloss(for entry: DictionaryEntry) -> String {
        entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
    }

    private func hasSavedWord(surface: String, reading: String?) -> Bool {
        let targetSurface = kanaFoldToHiragana(surface)
        if let reading {
            let targetKana = kanaFoldToHiragana(reading)
            return savedSurfaceKanaKeys.contains(SurfaceKanaKey(surface: targetSurface, kana: targetKana))
        }
        return savedSurfaceKeys.contains(targetSurface)
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSearchTaskID(mode: DictionarySearchMode, term: String) -> String {
        "\(mode == .english ? "EN" : "JP")|\(term)"
    }

    private var searchTaskID: String {
        makeSearchTaskID(mode: searchMode, term: trimmedSearchText)
    }

    /// Merge dictionary lookup results that differ only by kana script (hiragana/katakana)
    /// for the same headword, e.g. 僕 ぼく and 僕 ボク.
    private var mergedLookupResults: [DictionaryResultRow] {
        let entries = lookup.results
        guard entries.isEmpty == false else { return [] }

        var buckets: [String: DictionaryResultRow.Builder] = [:]
        var orderedKeys: [String] = []

        for entry in entries {
            let surface = displaySurface(for: entry)
            let rawKana = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kanaKey = rawKana.isEmpty ? "" : kanaFoldToHiragana(rawKana)
            let key = "\(surface)|\(kanaKey)"

            if var builder = buckets[key] {
                builder.entries.append(entry)
                buckets[key] = builder
            } else {
                buckets[key] = DictionaryResultRow.Builder(surface: surface, kanaKey: kanaKey, entries: [entry])
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { key in
            buckets[key]?.build(firstGlossFor: firstGloss(for:))
        }
    }

    private var hasActiveSearch: Bool {
        trimmedSearchText.isEmpty == false
    }

    private var isEditing: Bool {
        editModeState.isEditing
    }

    private var canEditSavedWords: Bool {
        hasActiveSearch == false && dictionaryHomeShelf == .favorites && store.words.isEmpty == false
    }

    private func deleteSelection() {
        guard selectedWordIDs.isEmpty == false else { return }
        store.delete(ids: selectedWordIDs)
        selectedWordIDs.removeAll()
    }

    private func selectAllSavedWords() {
        guard canEditSavedWords else { return }
        let allIDs = Set(cachedSortedWords.map { $0.id })
        if selectedWordIDs == allIDs {
            selectedWordIDs.removeAll()
        } else {
            selectedWordIDs = allIDs
        }
    }

    private func addSelection(toList listID: UUID) {
        guard selectedWordIDs.isEmpty == false else { return }
        store.addWords(ids: selectedWordIDs, toList: listID)
    }

    private func promptForNewListName() {
        pendingBulkAddListName = ""
        isPromptingForBulkAddListName = true
    }

    private func createListAndAddSelection() {
        let trimmed = pendingBulkAddListName.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingBulkAddListName = ""

        guard trimmed.isEmpty == false else { return }

        let normalized = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let targetList: WordList? = {
            if let created = store.createList(name: trimmed) {
                return created
            }
            return store.lists.first(where: { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized })
        }()

        if let list = targetList {
            addSelection(toList: list.id)
        }
    }
}

