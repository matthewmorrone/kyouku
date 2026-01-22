import SwiftUI
import UniformTypeIdentifiers

struct WordsView: View {
    @EnvironmentObject var store: WordsStore
    @EnvironmentObject var notesStore: NotesStore
    @StateObject private var lookup = DictionaryLookupViewModel()
    @State private var searchText: String = ""
    @State private var searchMode: DictionarySearchMode = .japanese
    @State private var editModeState: EditMode = .inactive
    @State private var selectedWordIDs: Set<Word.ID> = []
    @State private var showCSVImportSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                mainList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.editMode, $editModeState)
            .listStyle(.plain)
            .navigationTitle("Words")
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
                    if isEditing {
                        if canEditSavedWords {
                            Button {
                                selectAllSavedWords()
                            } label: {
                                Label("Select All", systemImage: "checkmark.circle")
                            }
                            .accessibilityLabel("Select all saved entries")
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
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(editModeState.isEditing ? "Done" : "Edit")
                    }
                }
            }
        }
        .task(id: searchTaskID) {
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
        .sheet(isPresented: $showCSVImportSheet) {
            NavigationStack {
                WordsCSVImportView()
            }
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
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
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
        } else {
            List(selection: $selectedWordIDs) {
                savedSection
            }
        }
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
            ForEach(mergedLookupResults) { row in
                NavigationLink {
                    WordDefinitionsView(
                        surface: row.surface,
                        kana: row.kana,
                        sourceNoteID: nil
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
                .foregroundStyle(.secondary)
        } else {
            ForEach(sortedWords) { word in
                if isEditing {
                    savedRow(word)
                        .tag(word.id)
                } else {
                    NavigationLink {
                        WordDefinitionsView(
                            surface: word.dictionarySurface ?? displayHeadword(for: word),
                            kana: word.kana,
                            sourceNoteID: word.sourceNoteID
                        )
                    } label: {
                        savedRow(word)
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
            if word.sourceNoteID != nil {
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
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
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

    private var sortedWords: [Word] {
        store.words.sorted { $0.createdAt > $1.createdAt }
    }

    private func performLookup() async {
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

        await lookup.load(term: term, mode: searchMode)
    }

    private func add(entry: DictionaryEntry) {
        let surface = displaySurface(for: entry)
        let gloss = firstGloss(for: entry)
        store.add(surface: surface, kana: entry.kana, meaning: gloss)
    }

    private func addMergedRow(_ row: DictionaryResultRow) {
        store.add(surface: row.surface, kana: row.kana, meaning: row.gloss)
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

        guard let noteID = word.sourceNoteID else {
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
        let targetKana = kanaFoldToHiragana(reading ?? "")
        return store.words.contains { word in
            guard kanaFoldToHiragana(word.surface) == targetSurface else { return false }
            if reading != nil {
                return kanaFoldToHiragana(word.kana ?? "") == targetKana
            }
            return true
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTaskID: String {
        "\(searchMode == .english ? "EN" : "JP")|\(trimmedSearchText)"
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

    private func selectAllSavedWords() {
        guard canEditSavedWords else { return }
        let allIDs = Set(sortedWords.map { $0.id })
        if selectedWordIDs == allIDs {
            selectedWordIDs.removeAll()
        } else {
            selectedWordIDs = allIDs
        }
    }
}

/// Lightweight view model for a merged dictionary result row.
private struct DictionaryResultRow: Identifiable {
    let surface: String
    let kana: String?
    let gloss: String

    var id: String { "\(surface)#\(kana ?? "(no-kana)")" }

    struct Builder {
        let surface: String
        let kanaKey: String
        var entries: [DictionaryEntry]

        func build(firstGlossFor: (DictionaryEntry) -> String) -> DictionaryResultRow? {
            guard let first = entries.first else { return nil }
            let allKana: [String] = entries.compactMap { $0.kana?.trimmingCharacters(in: .whitespacesAndNewlines) }
            let displayKana: String? = {
                let cleaned = allKana.filter { $0.isEmpty == false }
                guard cleaned.isEmpty == false else { return nil }

                func isAllHiragana(_ text: String) -> Bool {
                    guard text.isEmpty == false else { return false }
                    return text.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
                }

                if let hira = cleaned.first(where: isAllHiragana) { return hira }
                return cleaned.first
            }()

            let gloss = firstGlossFor(first)
            return DictionaryResultRow(surface: surface, kana: displayKana, gloss: gloss)
        }
    }
}

private extension EditMode {
    var isEditing: Bool {
        self != .inactive
    }
}

private struct WordsCSVImportView: View {
    @EnvironmentObject private var store: WordsStore

    @Environment(\.dismiss) private var dismiss
    @State private var rawText: String = ""
    @State private var isParsing: Bool = false
    @State private var items: [WordsCSVImportItem] = []
    @State private var errorText: String? = nil
    @State private var isFileImporterPresented: Bool = false

    private var importableItems: [WordsCSVImportItem] {
        items.filter { item in
            item.finalSurface?.isEmpty == false && item.finalMeaning?.isEmpty == false
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            inputControls
            csvEditor
            previewList
            importButton
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .navigationTitle("Import CSV")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    private var inputControls: some View {
        HStack(spacing: 12) {
            Button {
                isFileImporterPresented = true
            } label: {
                Label("Choose CSV", systemImage: "doc")
            }

            Spacer()

            Button {
                Task { await parse() }
            } label: {
                if isParsing {
                    ProgressView()
                } else {
                    Text("Parse")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isParsing || rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var csvEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste CSV text")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                )

            if let errorText, errorText.isEmpty == false {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 6) {
            let total = items.count
            let importable = importableItems.count
            Text(total == 0 ? "Parsed rows" : "Parsed rows: \(importable)/\(total) importable")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            List {
                if items.isEmpty {
                    Text("No rows parsed yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.finalSurface ?? "(missing surface)")
                                .font(.headline)
                            if let kana = item.finalKana, kana.isEmpty == false, kana != item.finalSurface {
                                Text(kana)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(item.finalMeaning ?? "(missing meaning)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var importButton: some View {
        Button {
            importWords()
            dismiss()
        } label: {
            Text("Import \(importableItems.count) Words")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(importableItems.isEmpty)
        .padding(.bottom, 8)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else {
                errorText = "No file selected."
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                errorText = "Failed to access the file."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                let decoded = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .unicode)
                    ?? String(data: data, encoding: .ascii)
                guard let decoded else {
                    errorText = "Could not decode the file contents."
                    return
                }
                rawText = decoded
                errorText = nil
                items = []
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    @MainActor
    private func parse() async {
        isParsing = true
        defer { isParsing = false }
        errorText = nil

        let text = rawText
        let parsed = WordsCSVImport.parseItems(from: text)
        var enriched = parsed
        await WordsCSVImport.fillMissing(items: &enriched)
        items = enriched
    }

    private func importWords() {
        for item in importableItems {
            guard let surface = item.finalSurface, surface.isEmpty == false else { continue }
            guard let meaning = item.finalMeaning, meaning.isEmpty == false else { continue }
            store.add(surface: surface, kana: item.finalKana, meaning: meaning, note: item.finalNote)
        }
    }
}

private struct WordsCSVImportItem: Identifiable, Hashable {
    let id: UUID
    let lineNumber: Int

    var providedSurface: String?
    var providedKana: String?
    var providedMeaning: String?
    var providedNote: String?

    var computedSurface: String?
    var computedKana: String?
    var computedMeaning: String?

    init(
        id: UUID = UUID(),
        lineNumber: Int,
        providedSurface: String?,
        providedKana: String?,
        providedMeaning: String?,
        providedNote: String?
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.providedSurface = providedSurface
        self.providedKana = providedKana
        self.providedMeaning = providedMeaning
        self.providedNote = providedNote
    }

    var finalSurface: String? {
        let raw = (providedSurface ?? computedSurface)
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var finalKana: String? {
        let raw = (providedKana ?? computedKana)
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var finalMeaning: String? {
        let raw = (providedMeaning ?? computedMeaning)
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var finalNote: String? {
        guard let raw = providedNote else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

private enum WordsCSVImport {
    static func parseItems(from text: String) -> [WordsCSVImportItem] {
        guard let firstNonEmptyLine = firstNonEmptyLine(in: text) else { return [] }
        if let delimiter = autoDelimiter(forFirstLine: firstNonEmptyLine) {
            return parseDelimited(text, delimiter: delimiter)
        }
        return parseListMode(text)
    }

    static func fillMissing(items: inout [WordsCSVImportItem]) async {
        guard items.isEmpty == false else { return }

        var updated = Array<WordsCSVImportItem?>(repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, WordsCSVImportItem).self) { group in
            for idx in items.indices {
                let original = items[idx]
                group.addTask {
                    var item = original

                    func localTrim(_ value: String?) -> String? {
                        guard let value else { return nil }
                        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }

                    func localFirstGloss(_ gloss: String) -> String {
                        gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? gloss
                    }

                    func localIsKanaOnly(_ text: String) -> Bool {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { return false }
                        var sawKana = false
                        for scalar in trimmed.unicodeScalars {
                            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                            switch scalar.value {
                            case 0x3040...0x309F, // Hiragana
                                 0x30A0...0x30FF, // Katakana
                                 0xFF66...0xFF9F: // Half-width katakana
                                sawKana = true
                            default:
                                return false
                            }
                        }
                        return sawKana
                    }

                    func localContainsJapaneseScript(_ text: String) -> Bool {
                        for scalar in text.unicodeScalars {
                            switch scalar.value {
                            case 0x3040...0x309F, // Hiragana
                                 0x30A0...0x30FF, // Katakana
                                 0xFF66...0xFF9F, // Half-width katakana
                                 0x3400...0x4DBF, // CJK Ext A
                                 0x4E00...0x9FFF, // CJK Unified
                                 0xF900...0xFAFF: // CJK Compatibility
                                return true
                            default:
                                continue
                            }
                        }
                        return false
                    }

                    let surface = localTrim(item.providedSurface ?? item.computedSurface)
                    let kana = localTrim(item.providedKana ?? item.computedKana)
                    let meaning = localTrim(item.providedMeaning ?? item.computedMeaning)

                    let needsSurface = (surface?.isEmpty ?? true)
                    let needsKana = (kana?.isEmpty ?? true)
                    let needsMeaning = (meaning?.isEmpty ?? true)
                    if needsSurface == false && needsKana == false && needsMeaning == false {
                        return (idx, item)
                    }

                    var candidates: [String] = []
                    if let s = surface, s.isEmpty == false { candidates.append(s) }
                    if let k = kana, k.isEmpty == false { candidates.append(k) }
                    // If the user pasted Japanese into the meaning column (or columns were shuffled),
                    // allow it to participate as a lookup candidate.
                    if let m = meaning, m.isEmpty == false, (localContainsJapaneseScript(m) || localIsKanaOnly(m)) {
                        candidates.append(m)
                    }
                    var seen = Set<String>()
                    candidates = candidates.filter { seen.insert($0).inserted }

                    var hit: DictionaryEntry? = nil
                    for cand in candidates {
                        let rows: [DictionaryEntry]
                        do {
                            rows = try await Task.detached(priority: .userInitiated, operation: { () async throws -> [DictionaryEntry] in
                                try await DictionarySQLiteStore.shared.lookup(term: cand, limit: 1)
                            }).value
                        } catch {
                            continue
                        }

                        if let first = rows.first {
                            hit = first
                            break
                        }
                    }

                    if let entry = hit {
                        if needsSurface {
                            let proposed = entry.kanji.isEmpty ? (entry.kana ?? "") : entry.kanji
                            if proposed.isEmpty == false {
                                item.computedSurface = proposed
                            }
                        }
                        if needsKana {
                            if let k = entry.kana, k.isEmpty == false {
                                item.computedKana = k
                            }
                        }
                        if needsMeaning {
                            let gloss = localFirstGloss(entry.gloss)
                            if gloss.isEmpty == false {
                                item.computedMeaning = gloss
                            }
                        }
                    }

                    return (idx, item)
                }
            }

            for await (idx, newItem) in group {
                updated[idx] = newItem
            }
        }

        for idx in items.indices {
            if let u = updated[idx] {
                items[idx] = u
            }
        }
    }

    // MARK: - Parsing helpers

    private static func parseListMode(_ text: String) -> [WordsCSVImportItem] {
        var out: [WordsCSVImportItem] = []
        var lineNo = 0
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            lineNo += 1
            let trimmedLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }

            if containsKanji(trimmedLine) {
                out.append(WordsCSVImportItem(lineNumber: lineNo, providedSurface: trimmedLine, providedKana: nil, providedMeaning: nil, providedNote: nil))
            } else if isKanaOnly(trimmedLine) {
                out.append(WordsCSVImportItem(lineNumber: lineNo, providedSurface: nil, providedKana: trimmedLine, providedMeaning: nil, providedNote: nil))
            } else {
                // Treat plain English / non-Japanese as meaning.
                out.append(WordsCSVImportItem(lineNumber: lineNo, providedSurface: nil, providedKana: nil, providedMeaning: trimmedLine, providedNote: nil))
            }
        }
        return out
    }

    private struct HeaderMap {
        var surfaceIndex: Int?
        var kanaIndex: Int?
        var meaningIndex: Int?
        var noteIndex: Int?
    }

    private static func parseDelimited(_ text: String, delimiter: Character) -> [WordsCSVImportItem] {
        var out: [WordsCSVImportItem] = []
        var lineNo = 0
        var headerMap: HeaderMap? = nil
        var didConsumeHeader = false

        for raw in text.components(separatedBy: CharacterSet.newlines) {
            lineNo += 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            let cols = splitCSVLine(line, delimiter: delimiter).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if headerMap == nil {
                if let maybeHeader = buildHeaderMap(from: cols) {
                    headerMap = maybeHeader
                    didConsumeHeader = true
                    continue
                }
            }

            let item: WordsCSVImportItem
            if let headerMap {
                let surface = headerMap.surfaceIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                let kana = headerMap.kanaIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                let meaning = headerMap.meaningIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                let note = headerMap.noteIndex.flatMap { cols.indices.contains($0) ? trim(cols[$0]) : nil }
                item = WordsCSVImportItem(lineNumber: lineNo, providedSurface: surface, providedKana: kana, providedMeaning: meaning, providedNote: note)
            } else {
                let classified = classifyRowCells(cols)
                item = WordsCSVImportItem(lineNumber: lineNo, providedSurface: classified.surface, providedKana: classified.kana, providedMeaning: classified.meaning, providedNote: classified.note)
            }

            // If there was a header line but it's empty/garbage, avoid consuming it accidentally.
            if didConsumeHeader {
                didConsumeHeader = false
            }

            out.append(item)
        }
        return out
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        for raw in text.components(separatedBy: CharacterSet.newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty == false {
                return line
            }
        }
        return nil
    }

    private static func autoDelimiter(forFirstLine line: String) -> Character? {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: (delim: Character, count: Int)? = nil
        for delim in candidates {
            let count = line.filter { $0 == delim }.count
            if count == 0 { continue }
            if best == nil || count > best!.count {
                best = (delim, count)
            }
        }
        return best?.delim
    }

    static func trim(_ value: String?) -> String? {
        guard let value else { return nil }
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func firstGloss(_ gloss: String) -> String {
        gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? gloss
    }

    private static func classifyRowCells(_ cols: [String]) -> (surface: String?, kana: String?, meaning: String?, note: String?) {
        let values = cols.compactMap { trim($0) }
        guard values.isEmpty == false else { return (nil, nil, nil, nil) }

        // Pick the best surface candidate.
        let kanjiSurface = values.first(where: { containsKanji($0) })
        let japaneseSurface = kanjiSurface ?? values.first(where: { containsJapaneseScript($0) })

        // Pick best kana candidate.
        let kana = values.first(where: { isKanaOnly($0) })
            ?? values.first(where: { containsJapaneseScript($0) && containsKanji($0) == false && looksLikeEnglish($0) == false })

        // Meaning: prefer clearly English-like, otherwise any non-Japanese leftover.
        let meaning = values.first(where: { looksLikeEnglish($0) })
            ?? values.first(where: { containsJapaneseScript($0) == false })

        // Note: anything left over that isn't the chosen surface/kana/meaning.
        var used = Set<String>()
        if let japaneseSurface { used.insert(japaneseSurface) }
        if let kana { used.insert(kana) }
        if let meaning { used.insert(meaning) }
        let noteParts = values.filter { used.contains($0) == false }
        let note = noteParts.isEmpty ? nil : noteParts.joined(separator: " ")

        return (japaneseSurface, kana, meaning, note)
    }

    private static func buildHeaderMap(from cols: [String]) -> HeaderMap? {
        // Heuristic: treat first row as a header if it contains at least two known header tokens.
        // Common variants are accepted (surface/kanji/word, kana/reading, meaning/gloss/definition, note/notes).
        var map = HeaderMap()
        var hits = 0

        for (idx, raw) in cols.enumerated() {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty { continue }

            if ["surface", "kanji", "word", "term", "vocab"].contains(key) {
                map.surfaceIndex = map.surfaceIndex ?? idx
                hits += 1
                continue
            }
            if ["kana", "reading", "yomi", "pronunciation"].contains(key) {
                map.kanaIndex = map.kanaIndex ?? idx
                hits += 1
                continue
            }
            if ["meaning", "gloss", "definition", "english", "en"].contains(key) {
                map.meaningIndex = map.meaningIndex ?? idx
                hits += 1
                continue
            }
            if ["note", "notes", "memo"].contains(key) {
                map.noteIndex = map.noteIndex ?? idx
                hits += 1
                continue
            }
        }

        return hits >= 2 ? map : nil
    }

    private static func containsKanji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, // CJK Ext A
                 0x4E00...0x9FFF, // CJK Unified
                 0xF900...0xFAFF: // CJK Compatibility
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func isKanaOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        var sawKana = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F: // Half-width katakana
                sawKana = true
            default:
                return false
            }
        }
        return sawKana
    }

    private static func containsJapaneseScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F, // Half-width katakana
                 0x3400...0x4DBF, // CJK Ext A
                 0x4E00...0x9FFF, // CJK Unified
                 0xF900...0xFAFF: // CJK Compatibility
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func looksLikeEnglish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        guard containsJapaneseScript(trimmed) == false else { return false }
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                return true
            }
        }
        return false
    }

    private static func splitCSVLine(_ line: String, delimiter: Character) -> [String] {
        var out: [String] = []
        out.reserveCapacity(4)

        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    let nextIndex = i + 1
                    if nextIndex < chars.count, chars[nextIndex] == "\"" {
                        current.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    current.append(ch)
                    i += 1
                    continue
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                    i += 1
                    continue
                }
                if ch == delimiter {
                    out.append(current)
                    current = ""
                    i += 1
                    continue
                }
                current.append(ch)
                i += 1
            }
        }

        out.append(current)
        return out
    }
}

