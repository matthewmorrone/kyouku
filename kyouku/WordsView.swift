//
//  SavedWordsView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI
import OSLog
import UniformTypeIdentifiers

fileprivate let wordsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Words")

struct WordsView: View {
    @EnvironmentObject var store: WordStore
    @State private var selectedWordIDs: Set<UUID> = []
    @State private var isSelecting: Bool = false
    @State private var searchText: String = ""
    @StateObject private var vm = DictionaryLookupViewModel()
    @State private var showingDefinition = false
    @State private var selectedWord: Word? = nil
    @State private var dictEntry: DictionaryEntry? = nil
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil
    @State private var searchTask: Task<Void, Never>? = nil

    // Import words state
    @State private var isImportingWords: Bool = false
    @State private var importError: String? = nil
    @State private var importSummary: String? = nil
    @State private var showImportError: Bool = false
    @State private var showImportSummary: Bool = false
    @State private var importPreviewURL: URL? = nil
    @State private var previewItems: [ImportPreviewItem] = []
    @State private var showImportPreview: Bool = false
    @State private var preferKanaOnly: Bool = false
    @State private var delimiterSelection: DelimiterChoice = .auto

    var body: some View {
        NavigationStack {
            List {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    savedWordsSection
                } else {
                    dictionarySection
                }
            }
            .navigationTitle("Words")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        if isSelecting {
                            isSelecting = false
                            selectedWordIDs.removeAll()
                        } else {
                            isSelecting = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImportingWords = true
                    } label: {
                        Label("Import", systemImage: "tray.and.arrow.down")
                    }
                    .help("Import Words…")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSelecting {
                        Button(role: .destructive) {
                            deleteSelectedWords()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selectedWordIDs.isEmpty)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search dictionary")
            .onChange(of: searchText) { oldValue, newValue in
                handleSearchTextChange(oldValue: oldValue, newValue: newValue)
            }
            .sheet(isPresented: $showingDefinition) {
                sheetContent
            }
            .fileImporter(isPresented: $isImportingWords, allowedContentTypes: [.commaSeparatedText, .plainText], onCompletion: handleWordsImport)
            .sheet(isPresented: $showImportPreview) {
                makeImportPreviewSheet()
                    .presentationDetents([.large])
            }
            .onChange(of: delimiterSelection) { _, _ in
                reloadPreviewForDelimiter()
            }
            .alert("Import Error", isPresented: $showImportError, actions: {
                Button("OK") { showImportError = false; importError = nil }
            }, message: {
                Text(importError ?? "Unknown error")
            })
            .alert("Import Summary", isPresented: $showImportSummary) {
                Button("OK") { showImportSummary = false; importSummary = nil }
            } message: {
                Text(importSummary ?? "")
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 12) {
                            Button("Cancel") {
                                isSelecting = false
                                selectedWordIDs.removeAll()
                            }
                            Spacer()
                            Button(role: .destructive) {
                                deleteSelectedWords()
                            } label: {
                                Text("Delete Selected (\(selectedWordIDs.count))")
                            }
                            .disabled(selectedWordIDs.isEmpty)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .background(.regularMaterial)
                }
            }
        }
    }
    
    // MARK: - Subviews

    @ViewBuilder
    private var dictionarySection: some View {
        Section("Dictionary") {
            if vm.isLoading {
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
                            Text(displaySurface(for: entry))
                                .font(.headline)
                            Text(firstGloss(for: entry))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            let surface = displaySurface(for: entry)
                            let meaning = firstGloss(for: entry)
                            store.add(surface: surface, reading: entry.reading, meaning: meaning)
                        } label: {
                            if isSaved(entry) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaved(entry))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var savedWordsSection: some View {
        Section("Saved Words") {
            ForEach(sortedWords) { word in
                HStack(alignment: .top, spacing: 8) {
                    if isSelecting {
                        Button(action: {
                            if selectedWordIDs.contains(word.id) {
                                selectedWordIDs.remove(word.id)
                            } else {
                                selectedWordIDs.insert(word.id)
                            }
                        }) {
                            Image(systemName: selectedWordIDs.contains(word.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedWordIDs.contains(word.id) ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
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
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelecting {
                        if selectedWordIDs.contains(word.id) {
                            selectedWordIDs.remove(word.id)
                        } else {
                            selectedWordIDs.insert(word.id)
                        }
                    } else {
                        selectedWord = word
//                        if let w = selectedWord {
//                            wordsLogger.info("Saved word tapped: surface='\(w.surface, privacy: .public)', reading='\(w.reading, privacy: .public)'")
//                        }
                        showingDefinition = true
                        Task { await lookup(for: word) }
                    }
                }
            }
            .onDelete(perform: deleteSavedWords)
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
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
                    Button(action: {
                        // Selected word already has a meaning; route through the single add method.
                        if let w = selectedWord {
                            store.add(surface: w.surface, reading: w.reading, meaning: w.meaning)
                        }
                        showingDefinition = false
                    }) {
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
                    Button(action: {
                        let surface = displaySurface(for: entry)
                        let meaning = firstGloss(for: entry)
                        store.add(surface: surface, reading: entry.reading, meaning: meaning)
                        showingDefinition = false
                    }) {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    Spacer()
                    Button(action: { showingDefinition = false }) {
                        Image(systemName: "xmark.circle.fill").font(.title3)
                    }
                }

                Text(displaySurface(for: entry))
                    .font(.title2).bold()
                if !entry.reading.isEmpty {
                    Text(entry.reading)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(firstGloss(for: entry))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .presentationDetents([.medium, .large])
        } else {
            VStack {
                Text("No definition found")
                Button("Close") { showingDefinition = false }
            }
            .padding()
        }
    }

    // MARK: - Helpers

    private var sortedWords: [Word] {
        store.words.sorted(by: { $0.createdAt > $1.createdAt })
    }
    
    private func handleSearchTextChange(oldValue: String, newValue: String) {
        // Cancel any in-flight search task
        searchTask?.cancel()
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            vm.results = []
            vm.errorMessage = nil
            return
        }
        // Debounce 350ms
        searchTask = Task { [trimmed] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await vm.load(term: trimmed)
        }
    }

    private func deleteSavedWords(at offsets: IndexSet) {
        let ids = Set(offsets.map { sortedWords[$0].id })
        store.delete(ids: ids)
    }

    private func deleteSelectedWords() {
        let ids = selectedWordIDs
        guard !ids.isEmpty else { return }
        store.delete(ids: ids)
        selectedWordIDs.removeAll()
        isSelecting = false
    }

    private func displaySurface(for entry: DictionaryEntry) -> String {
        entry.kanji.isEmpty ? entry.reading : entry.kanji
    }

    private func firstGloss(for entry: DictionaryEntry) -> String {
        entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
    }

    private func isSaved(_ entry: DictionaryEntry) -> Bool {
        let surface = displaySurface(for: entry)
        return store.words.contains { $0.surface == surface && $0.reading == entry.reading }
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
            if let e = dictEntry {
                let surface = e.kanji.isEmpty ? e.reading : e.kanji
                let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
                wordsLogger.info("Popup will show: surface='\(surface, privacy: .public)', reading='\(e.reading, privacy: .public)', gloss='\(firstGloss, privacy: .public)'")
            } else if let w = selectedWord {
                wordsLogger.info("Popup will show: no definitions found for surface='\(w.surface, privacy: .public)', reading='\(w.reading, privacy: .public)'")
            }
        } catch {
            await MainActor.run {
                lookupError = (error as? DictionarySQLiteError)?.description ?? error.localizedDescription
                isLookingUp = false
            }
        }
    }

    // MARK: - Import Words Support
    private func toImporterItems(_ items: [ImportPreviewItem]) -> [WordImporter.ImportItem] {
        return items.map { it in
            WordImporter.ImportItem(
                lineNumber: it.lineNumber,
                providedSurface: it.providedSurface,
                providedReading: it.providedReading,
                providedMeaning: it.providedMeaning,
                note: it.note,
                computedSurface: it.computedSurface,
                computedReading: it.computedReading,
                computedMeaning: it.computedMeaning
            )
        }
    }
    
    private func reloadPreviewForDelimiter() {
        guard let url = importPreviewURL else { return }
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) ?? String(data: data, encoding: .ascii) else { return }
            let chosen: DelimiterChoice = (delimiterSelection == .auto) ? bestGuessDelimiter(for: text) : delimiterSelection
            let delimiterChar = chosen.character
            let items = (delimiterChar == nil) ? WordImporter.parseItems(fromString: text) : WordImporter.parseItems(fromString: text, delimiter: delimiterChar)
            self.updatePreviewItems(from: items)
        } catch {
            // leave previous preview intact
        }
    }

    private func updatePreviewItems(from importerItems: [WordImporter.ImportItem]) {
        self.previewItems = importerItems.map { it in
            ImportPreviewItem(
                lineNumber: it.lineNumber,
                providedSurface: it.providedSurface,
                providedReading: it.providedReading,
                providedMeaning: it.providedMeaning,
                note: it.note,
                computedSurface: it.computedSurface,
                computedReading: it.computedReading,
                computedMeaning: it.computedMeaning
            )
        }
    }

    @MainActor
    private func fillMissingForPreviewItems() async {
        var importerItems = toImporterItems(self.previewItems)
        await WordImporter.fillMissing(items: &importerItems, preferKanaOnly: self.preferKanaOnly)
        updatePreviewItems(from: importerItems)
    }

    private func finalizePreviewItems() -> [(surface: String, reading: String, meaning: String, note: String?)] {
        let prepared = WordImporter.finalize(items: toImporterItems(self.previewItems), preferKanaOnly: self.preferKanaOnly)
        return prepared.map { (surface: $0.surface, reading: $0.reading, meaning: $0.meaning, note: $0.note) }
    }

    private func handleWordsImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) ?? String(data: data, encoding: .ascii) else {
                    throw NSError(domain: "Import", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported text encoding."])
                }
                // Determine delimiter
                let chosen: DelimiterChoice = (delimiterSelection == .auto) ? bestGuessDelimiter(for: text) : delimiterSelection
                let delimiterChar = chosen.character
                let items = (delimiterChar == nil) ? WordImporter.parseItems(fromString: text) : WordImporter.parseItems(fromString: text, delimiter: delimiterChar)
                importPreviewURL = url
                self.updatePreviewItems(from: items)
                showImportPreview = true
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }
        case .failure(let err):
            importError = err.localizedDescription
            showImportError = true
        }
    }

    @ViewBuilder
    private func makeImportPreviewSheet() -> some View {
        WordsImportPreviewSheet(
            items: $previewItems,
            preferKanaOnly: $preferKanaOnly,
            delimiter: $delimiterSelection,
            onFill: {
                Task { await fillMissingForPreviewItems() }
            },
            onConfirm: {
                let prepared = finalizePreviewItems()
                var added = 0
                for w in prepared {
                    let before = store.allWords().count
                    store.add(surface: w.surface, reading: w.reading, meaning: w.meaning, note: w.note)
                    let after = store.allWords().count
                    if after > before { added += 1 }
                }
                importSummary = "Imported words: \(added). Skipped: \(prepared.count - added)."
                showImportSummary = true
                showImportPreview = false
            },
            onCancel: {
                showImportPreview = false
            }
        )
    }

    // Local mirror for preview items used by the import sheet
    private struct ImportPreviewItem: Identifiable, Hashable {
        let id: UUID
        let lineNumber: Int
        var providedSurface: String?
        var providedReading: String?
        var providedMeaning: String?
        var note: String?
        var computedSurface: String?
        var computedReading: String?
        var computedMeaning: String?

        init(id: UUID = UUID(), lineNumber: Int, providedSurface: String?, providedReading: String?, providedMeaning: String?, note: String?, computedSurface: String?, computedReading: String?, computedMeaning: String?) {
            self.id = id
            self.lineNumber = lineNumber
            self.providedSurface = providedSurface
            self.providedReading = providedReading
            self.providedMeaning = providedMeaning
            self.note = note
            self.computedSurface = computedSurface
            self.computedReading = computedReading
            self.computedMeaning = computedMeaning
        }
    }

    private enum DelimiterChoice: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case comma = ","
        case semicolon = ";"
        case tab = "\t"
        case pipe = "|"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .comma: return ", (comma)"
            case .semicolon: return "; (semicolon)"
            case .tab: return "Tab"
            case .pipe: return "| (pipe)"
            }
        }
        var character: Character? {
            switch self {
            case .auto: return nil
            case .comma: return ","
            case .semicolon: return ";"
            case .tab: return "\t"
            case .pipe: return "|"
            }
        }
    }

    private struct WordsImportPreviewSheet: View {
        @Binding var items: [ImportPreviewItem]
        @Binding var preferKanaOnly: Bool
        @Binding var delimiter: DelimiterChoice
        var onFill: () -> Void
        var onConfirm: () -> Void
        var onCancel: () -> Void

        var body: some View {
            NavigationStack {
                List {
                    Section("Options") {
                        Toggle("Prefer kana-only surface when only kana provided", isOn: $preferKanaOnly)
                            .tint(.accentColor)
                        Picker("Column Delimiter", selection: $delimiter) {
                            ForEach(DelimiterChoice.allCases) { choice in
                                Text(choice.displayName).tag(choice)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Section("Preview") {
                        if items.isEmpty {
                            Text("No items parsed.").foregroundStyle(.secondary)
                        } else {
                            ForEach(items) { it in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text((it.providedSurface ?? it.computedSurface) ?? "—")
                                            .font(.headline)
                                        let kana = (it.providedReading ?? it.computedReading) ?? ""
                                        if !kana.isEmpty {
                                            Text(kana)
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    if let m = (it.providedMeaning ?? it.computedMeaning), !m.isEmpty {
                                        Text(m)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    } else {
                                        Text("<no meaning>")
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                    }
                                    if let n = it.note, !n.isEmpty {
                                        Text(n)
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .navigationTitle("Import Preview")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { onCancel() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            Button("Fill Missing") { onFill() }
                            Button("Confirm") { onConfirm() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private func bestGuessDelimiter(for text: String) -> DelimiterChoice {
        let candidates: [DelimiterChoice] = [.comma, .semicolon, .tab, .pipe]
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) else {
            return .comma
        }
        var best: (DelimiterChoice, Int) = (.comma, 1)
        for c in candidates {
            if let ch = c.character {
                let parts = firstLine.split(separator: ch)
                if parts.count > best.1 { best = (c, parts.count) }
            }
        }
        return best.0
    }
}

