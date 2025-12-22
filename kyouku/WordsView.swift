//
//  SavedWordsView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import SwiftUI
import OSLog
import UniformTypeIdentifiers
import UIKit

fileprivate let wordsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "App", category: "Words")

/// Preference key used to collect the frames of word rows by their UUID.

struct WordsView: View {
    @EnvironmentObject var store: WordsStore
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

    @StateObject private var importVM = WordsImportViewModel()
    
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var isDraggingSelection: Bool = false
    @State private var dragSelectionMode: Bool? = nil // true = selecting, false = deselecting
    @State private var lastDragHitIDs: Set<UUID> = []

    private func vmBinding<T>(_ keyPath: ReferenceWritableKeyPath<WordsImportViewModel, T>) -> Binding<T> {
        Binding(
            get: { importVM[keyPath: keyPath] },
            set: { importVM[keyPath: keyPath] = $0 }
        )
    }
    
    @ViewBuilder
    private func legendTag(color: Color, text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    var body: some View {
        NavigationStack {
            mainList
                .coordinateSpace(name: "WordsListSpace")
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isSelecting else { return }
                            isDraggingSelection = true
                            // Current drag point in list space
                            let point = value.location
                            // Determine which rows intersect this vertical position
                            for (id, frame) in rowFrames {
                                guard frame.minY <= point.y && point.y <= frame.maxY else { continue }
                                // Limit interaction to the left area where the checkbox appears (approx 44pt)
                                let leftEdgeThreshold: CGFloat = 60
                                guard point.x <= frame.minX + leftEdgeThreshold else { continue }

                                // Establish selection mode based on the first hit
                                if dragSelectionMode == nil {
                                    dragSelectionMode = !selectedWordIDs.contains(id)
                                }

                                // Avoid toggling the same row multiple times in one drag
                                if lastDragHitIDs.contains(id) { continue }
                                lastDragHitIDs.insert(id)

                                if dragSelectionMode == true {
                                    selectedWordIDs.insert(id)
                                } else {
                                    selectedWordIDs.remove(id)
                                }
                            }
                        }
                        .onEnded { _ in
                            isDraggingSelection = false
                            dragSelectionMode = nil
                            lastDragHitIDs.removeAll()
                            // Provide light haptic feedback to signal end of selection gesture
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                        }
                )
            .navigationTitle("Words")
            .toolbar { wordsToolbar }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search dictionary"))
            .onChange(of: searchText) { oldValue, newValue in
                handleSearchTextChange(oldValue: oldValue, newValue: newValue)
            }
            .sheet(isPresented: $showingDefinition) { definitionSheetContent }
            .fileImporter(isPresented: vmBinding(\.isImportingWords), allowedContentTypes: [.commaSeparatedText, .plainText], allowsMultipleSelection: true, onCompletion: importVM.handleWordsImport)
            .sheet(isPresented: vmBinding(\.showImportPaste)) { importPasteSheetContent }
            .sheet(isPresented: vmBinding(\.showImportPreview)) {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            legendTag(color: .orange, text: "Kanji/Mixed")
                            legendTag(color: .blue, text: "Kana")
                            legendTag(color: .green, text: "English")
                        }
                        .padding(.horizontal)
                        
                        WordsImportPreviewSheet(
                            items: vmBinding(\.previewItems),
                            preferKanaOnly: vmBinding(\.preferKanaOnly),
                            onFill: {
                                await importVM.fillMissingForPreviewItems()
                                // No further action needed; @Published bindings will update the preview immediately
                            },
                            onConfirm: {
                                let prepared = importVM.finalizePreviewItems()
                                var added = 0
                                for w in prepared {
                                    let before = store.allWords().count
                                    let normalized = normalizeSurfaceReading(surface: w.surface, reading: w.reading)
                                    store.add(surface: normalized.surface, reading: normalized.reading, meaning: w.meaning, note: w.note)
                                    let after = store.allWords().count
                                    if after > before { added += 1 }
                                }
                                importVM.importSummary = "Imported words: \(added). Skipped: \(prepared.count - added)."
                                importVM.showImportSummary = true
                                importVM.showImportPreview = false
                            },
                            onCancel: {
                                importVM.showImportPreview = false
                                importVM.showImportPaste = true
                            }
                        )
                    }
                }
                .navigationTitle("Import Preview")
                .presentationDetents([PresentationDetent.large])
            }
            .onChange(of: importVM.delimiterSelection) { _, _ in
                importVM.reloadPreviewForDelimiter()
            }
            .alert("Import Error", isPresented: vmBinding(\.showImportError), actions: {
                Button("OK") { importVM.showImportError = false; importVM.importError = nil }
            }, message: {
                Text(importVM.importError ?? "Unknown error")
            })
            .alert("Import Summary", isPresented: vmBinding(\.showImportSummary)) {
                Button("OK") { importVM.showImportSummary = false }
            } message: {
                Text(importVM.importSummary ?? "")
            }
            .safeAreaInset(edge: .bottom) {
                SelectionBarView(
                    isSelecting: $isSelecting,
                    selectedWordIDs: $selectedWordIDs,
                    onDelete: { deleteSelectedWords() }
                )
            }
        }
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var wordsToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    if isSelecting {
                        // Finish selection
                        isSelecting = false
                        selectedWordIDs.removeAll()
                    } else {
                        isSelecting = true
                        hideKeyboard()
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    // Import from file
                    importVM.isImportingWords = true
                } label: {
                    Label("Import from File…", systemImage: "doc.badge.plus")
                }
                Button {
                    // Paste / Preview
                    importVM.showImportPaste = true
                } label: {
                    Label("Paste / Preview…", systemImage: "doc.on.clipboard")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
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

    // MARK: - Japanese text helpers
    private func containsKanji(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) || // CJK Unified Ideographs
               (0x3400...0x4DBF).contains(scalar.value) || // CJK Unified Ideographs Extension A
               (0xF900...0xFAFF).contains(scalar.value) {  // CJK Compatibility Ideographs
                return true
            }
        }
        return false
    }

    private func isKana(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let isHiragana = (0x3040...0x309F).contains(v)
            let isKatakana = (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
            let isProlonged = v == 0x30FC // ー
            let isSmallTsu = v == 0x3063 || v == 0x30C3
            let isPunctuation = v == 0x3001 || v == 0x3002 // 、 。
            if !(isHiragana || isKatakana || isProlonged || isSmallTsu || isPunctuation) {
                return false
            }
        }
        return true
    }

    private func normalizeSurfaceReading(surface: String, reading: String) -> (surface: String, reading: String) {
        var s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        var r = reading.trimmingCharacters(in: .whitespacesAndNewlines)

        // If both look like kana, keep as-is
        // If both contain kanji or neither are kana, keep original order
        // If one is kana and the other is kanji/mixed, ensure s=kanji/mixed and r=kana
        let sIsKana = isKana(s)
        let rIsKana = isKana(r)
        let sHasKanji = containsKanji(s)
        let rHasKanji = containsKanji(r)

        if sIsKana && !rIsKana {
            // reading in surface, swap
            swap(&s, &r)
        } else if !sHasKanji && rHasKanji {
            // kana in surface, kanji in reading, swap
            swap(&s, &r)
        }
        return (s, r)
    }

    @ViewBuilder
    private func makeImportPreviewSheet() -> some View {
        WordsImportPreviewSheet(
            items: vmBinding(\.previewItems),
            preferKanaOnly: vmBinding(\.preferKanaOnly),
            onFill: {
                await importVM.fillMissingForPreviewItems()
                // No further action needed; @Published bindings will update the preview immediately
            },
            onConfirm: {
                let prepared = importVM.finalizePreviewItems()
                var added = 0
                for w in prepared {
                    let before = store.allWords().count
                    let normalized = normalizeSurfaceReading(surface: w.surface, reading: w.reading)
                    store.add(surface: normalized.surface, reading: normalized.reading, meaning: w.meaning, note: w.note)
                    let after = store.allWords().count
                    if after > before { added += 1 }
                }
                importVM.importSummary = "Imported words: \(added). Skipped: \(prepared.count - added)."
                importVM.showImportSummary = true
                importVM.showImportPreview = false
            },
            onCancel: {
                importVM.showImportPreview = false
                importVM.showImportPaste = true
            }
        )
    }

    @ViewBuilder
    private var definitionSheetContent: some View {
        DefinitionSheetView(
            isLookingUp: isLookingUp,
            selectedWord: selectedWord,
            lookupError: lookupError,
            dictEntry: dictEntry,
            onAddFromWord: { w in
                store.add(surface: w.surface, reading: w.reading, meaning: w.meaning)
            },
            onAddFromEntry: { entry in
                let surface = entry.kanji.isEmpty ? entry.reading : entry.kanji
                let meaning = entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
                store.add(surface: surface, reading: entry.reading, meaning: meaning)
            },
            onClose: { showingDefinition = false }
        )
    }

    @ViewBuilder
    private var importPasteSheetContent: some View {
        ImportPasteSheetView(
            importRawText: vmBinding(\.importRawText),
            isImportingWords: vmBinding(\.isImportingWords),
            delimiterSelection: vmBinding(\.delimiterSelection),
            onPreview: { items in
                importVM.updatePreviewItems(from: items)
                importVM.showImportPreview = true
            },
            onClose: { importVM.showImportPaste = false }
        )
        .presentationDetents([PresentationDetent.large])
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var mainList: some View {
        List { listContent }
            .onPreferenceChange(WordRowFramePreferenceKey.self) { value in
                rowFrames = value
            }
    }

    @ViewBuilder
    private var listContent: some View {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SavedWordsSectionView(
                words: sortedWords,
                isSelecting: $isSelecting,
                selectedWordIDs: $selectedWordIDs,
                onDelete: deleteSavedWords,
                onWordTapped: { word in
                    selectedWord = word
                    showingDefinition = true
                    Task { await lookup(for: word) }
                }
            )
        } else {
            DictionarySectionView(
                vm: vm,
                isSaved: { entry in isSaved(entry) },
                onAdd: { entry in
                    let surface = displaySurface(for: entry)
                    let meaning = firstGloss(for: entry)
                    store.add(surface: surface, reading: entry.reading, meaning: meaning)
                }
            )
        }
    }
}

