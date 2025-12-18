//
//  NotesView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI

struct NotesView: View {
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var store: WordStore
    @State private var pendingDeleteOffsets: IndexSet? = nil
    @State private var showDeleteAlert: Bool = false
    @State private var pendingDeleteHasAssociatedWords: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if notesStore.notes.isEmpty {
                    Button {
                        router.noteToOpen = nil
                        router.selectedTab = .paste
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No notes yet")
                                .font(.headline)
                            Text("Workflow: paste text → save note → pick words → study.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    ForEach(notesStore.notes) { note in
                        Button {
                            router.noteToOpen = note
                            router.selectedTab = .paste
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(note.title?.isEmpty == false ? note.title! : "Untitled")
                                    .font(.headline)

                                Text(note.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete { offsets in
                        pendingDeleteOffsets = offsets
                        var hasAssociatedWords = false
                        for index in offsets {
                            guard index < notesStore.notes.count else { continue }
                            let noteID = notesStore.notes[index].id
                            if store.words.contains(where: { $0.sourceNoteID == noteID }) {
                                hasAssociatedWords = true
                                break
                            }
                        }
                        pendingDeleteHasAssociatedWords = hasAssociatedWords
                        showDeleteAlert = true
                    }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { PasteView.createNewNote(notes: notesStore, router: router) }) {
                        Image(systemName: "plus.square").font(.title2)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            .confirmationDialog("Delete note?", isPresented: $showDeleteAlert, titleVisibility: .visible) {
                if pendingDeleteHasAssociatedWords {
                    Button("Delete note and associated words", role: .destructive) {
                        handleDeleteNotes(deleteWords: true)
                    }
                }
                Button(pendingDeleteHasAssociatedWords ? "Delete note only" : "Delete note", role: .destructive) {
                    handleDeleteNotes(deleteWords: false)
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteOffsets = nil
                    pendingDeleteHasAssociatedWords = false
                }
            } message: {
                if pendingDeleteHasAssociatedWords {
                    Text("Do you also want to delete any words saved from this note?")
                } else {
                    Text("This will delete the selected note(s).")
                }
            }
        }
    }

    private func handleDeleteNotes(deleteWords: Bool) {
        guard let offsets = pendingDeleteOffsets else { return }
        let ids = offsets.map { notesStore.notes[$0].id }
        // Delete notes first
        notesStore.notes.remove(atOffsets: offsets)
        notesStore.save()
        // Optionally delete associated words
        if deleteWords {
            for id in ids {
                store.deleteWords(fromNoteID: id)
            }
        }
        pendingDeleteOffsets = nil
        pendingDeleteHasAssociatedWords = false
    }
}


//
//  Detail View for a Single Note
//

struct NoteDetailView: View {
    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notesStore: NotesStore
    let note: Note

    @State private var showFurigana = true
    @State private var isEditing: Bool = false

    @State private var editableTitle: String = ""
    @State private var editableText: String = ""

    @State private var selectedToken: ParsedToken? = nil
    @State private var selectedTokenRange: NSRange? = nil
    @State private var showingDefinition = false

    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil
    @State private var segVM: SegmentedTextViewModel? = nil
    @State private var fallbackTranslation: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                NavigationLink("Extract Words") {
                    ExtractWordsView(text: editableText.isEmpty ? note.text : editableText, sourceNoteID: note.id)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }

            TextField("Title", text: $editableTitle)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.roundedBorder)

            FuriganaTextEditor(
                text: $editableText,
                showFurigana: showFurigana,
                isEditable: !showFurigana && isEditing,
                allowTokenTap: !isEditing,
                onTokenTap: { token in
                    selectedToken = token
                    selectedTokenRange = token.range
                    showingDefinition = true
                    Task {
                        await lookupDefinitions(for: token)
                    }
                },
                onSelectionCleared: {
                    selectedToken = nil
                    selectedTokenRange = nil
                    showingDefinition = false
                    dictResults = []
                    isLookingUp = false
                    lookupError = nil
                    fallbackTranslation = nil
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)

            if let segVM {
                SegmentedTextView(viewModel: segVM)
                    .onChange(of: segVM.selected) { _, newSelected in
                        guard let selected = newSelected else { return }
                        let token = ParsedToken(surface: selected.surface, reading: "", meaning: "")
                        selectedToken = token
                        selectedTokenRange = nil
                        showingDefinition = true
                        Task {
                            await lookupDefinitions(for: token)
                        }
                    }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditing.toggle()
                    if isEditing { showFurigana = false }
                } label: {
                    Label(isEditing ? "Editing" : "Edit", systemImage: isEditing ? "pencil.circle.fill" : "pencil.circle")
                }
                .tint(isEditing ? .orange : .secondary)
                .help(isEditing ? "Stop Editing" : "Edit")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    notesStore.notes = notesStore.notes.map { n in
                        if n.id == note.id {
                            return Note(id: n.id, title: editableTitle.isEmpty ? nil : editableTitle, text: editableText, createdAt: n.createdAt)
                        } else {
                            return n
                        }
                    }
                    notesStore.save()
                    isEditing = false
                }
                .disabled(!isEditing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFurigana.toggle()
                } label: {
                    Label(showFurigana ? "Furigana On" : "Furigana Off", systemImage: showFurigana ? "textformat.superscript" : "textformat")
                }
                .tint(showFurigana ? .blue : .secondary)
                .disabled(isEditing)
            }
        }
        .sheet(isPresented: $showingDefinition) {
            if let token = selectedToken {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(action: {
                            if let first = dictResults.first {
                                let surface = first.kanji.isEmpty ? first.reading : first.kanji
                                let firstGloss = first.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? first.gloss
                                store.add(surface: surface, reading: first.reading, meaning: firstGloss, sourceNoteID: note.id)
                            } else if let translation = fallbackTranslation, translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                                store.add(surface: token.surface, reading: token.reading, meaning: translation, sourceNoteID: note.id)
                            } else {
                                // Fallback: attempt to add the tapped token if it already has a meaning; otherwise WordStore.add will ignore empty meanings
                                let fallbackMeaning = token.meaning ?? ""
                                store.add(surface: token.surface, reading: token.reading, meaning: fallbackMeaning, sourceNoteID: note.id)
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
                    HStack(spacing: 12) {
                        Button("Combine Left") {
                            combineToken(direction: .left)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedTokenRange == nil)

                        Button("Combine Right") {
                            combineToken(direction: .right)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedTokenRange == nil)
                    }

                    // Prefer DB entry values, fallback to token while loading
                    let entry = dictResults.first
                    let displayKanji = entry.map { $0.kanji.isEmpty ? $0.reading : $0.kanji } ?? token.surface
                    let displayKana = entry?.reading ?? token.reading

                    Text(displayKanji)
                        .font(.title2).bold()

                    if !displayKana.isEmpty && displayKana != displayKanji {
                        Text(displayKana)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }

                    if isLookingUp {
                        ProgressView("Looking up definitions…")
                    } else if let err = lookupError {
                        Text(err).foregroundStyle(.secondary)
                    } else if let e = entry {
                        let firstGloss = e.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.gloss
                        Text(firstGloss)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let translation = fallbackTranslation, translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Apple Translation")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text(translation)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("No definitions found.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .presentationDetents([.fraction(0.33)])
                .presentationDragIndicator(.visible)
            } else {
                Text("No selection")
                    .padding()
            }
        }
        .onAppear {
            editableTitle = note.title ?? ""
            editableText = note.text
            isEditing = editableText.isEmpty
            if isEditing { showFurigana = false }

            let initialText = editableText.isEmpty ? note.text : editableText
            let engine = SegmentationEngine.current()
            if engine == .appleTokenizer {
                if segVM == nil {
                    segVM = SegmentedTextViewModel(text: initialText, trie: nil)
                } else {
                    segVM?.text = initialText
                    segVM?.recomputeSegments()
                }
            } else if let trie = JMdictTrieCache.shared {
                if segVM == nil {
                    segVM = SegmentedTextViewModel(text: initialText, trie: trie)
                } else {
                    segVM?.trie = trie
                    segVM?.text = initialText
                    segVM?.recomputeSegments()
                }
            } else {
                Task {
                    let trie = await JMdictTrieProvider.shared.getTrie() ?? CustomTrieProvider.makeTrie()
                    if let trie {
                        await MainActor.run {
                            JMdictTrieCache.shared = trie
                            if segVM == nil {
                                segVM = SegmentedTextViewModel(text: initialText, trie: trie)
                            } else {
                                segVM?.trie = trie
                                segVM?.text = initialText
                                segVM?.recomputeSegments()
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: editableText) { _, newValue in
            segVM?.text = newValue
            segVM?.recomputeSegments()
        }
    }

    private func lookupDefinitions(for token: ParsedToken) async {
        await MainActor.run {
            isLookingUp = true
            lookupError = nil
            dictResults = []
            fallbackTranslation = nil
        }
        do {
            var results = try await DictionarySQLiteStore.shared.lookup(term: token.surface, limit: 1)
            if results.isEmpty && !token.reading.isEmpty {
                let alt = try await DictionarySQLiteStore.shared.lookup(term: token.reading, limit: 1)
                if !alt.isEmpty { results = alt }
            }

            if results.isEmpty {
                if let translation = await TranslationFallback.translate(surface: token.surface, reading: token.reading) {
                    await MainActor.run {
                        fallbackTranslation = translation
                    }
                }
            } else {
                await MainActor.run {
                    fallbackTranslation = nil
                }
            }
            await MainActor.run {
                dictResults = results
                isLookingUp = false
            }
        } catch {
            await MainActor.run {
                lookupError = (error as? DictionarySQLiteError)?.description ?? error.localizedDescription
                isLookingUp = false
                fallbackTranslation = nil
            }
        }
    }

    private enum CombineDirection { case left, right }

    private func combineToken(direction: CombineDirection) {
        guard let segVM else { return }
        let text = editableText.isEmpty ? note.text : editableText
        guard let nsRange = selectedTokenRange, nsRange.location != NSNotFound, nsRange.length > 0 else { return }

        // Build current segments
        let segments = segVM.segments
        guard !segments.isEmpty else { return }

        // Find the index of the selected segment by matching NSRange
        let selectedIndex: Int? = {
            for (i, s) in segments.enumerated() {
                let ns = NSRange(s.range, in: text)
                if ns.location == nsRange.location && ns.length == nsRange.length { return i }
            }
            return nil
        }()
        guard let idx = selectedIndex else { return }

        let neighborIndex: Int? = {
            switch direction {
            case .left:
                return idx > 0 ? idx - 1 : nil
            case .right:
                return (idx + 1) < segments.count ? idx + 1 : nil
            }
        }()
        guard let nIdx = neighborIndex else { return }

        let a = direction == .left ? segments[nIdx] : segments[idx]
        let b = direction == .left ? segments[idx] : segments[nIdx]

        // Only combine if contiguous
        guard a.range.upperBound == b.range.lowerBound else { return }

        let combinedSurface = a.surface + b.surface
        // Add to custom lexicon and rebuild trie cache
        _ = CustomTokenizerLexicon.add(word: combinedSurface)

        // Refresh the SegmentedTextViewModel to use the updated trie
        if let newTrie = JMdictTrieCache.shared ?? CustomTrieProvider.makeTrie() {
            segVM.trie = newTrie
        }
        segVM.invalidateSegmentation()

        // Also update the FuriganaTextEditor by toggling its text binding to force rebuild
        editableText = String(text)

        // Clear selection and close the sheet to avoid stale state
        selectedToken = nil
        selectedTokenRange = nil
        showingDefinition = false
    }
}

