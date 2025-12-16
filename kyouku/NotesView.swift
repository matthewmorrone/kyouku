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
                    .onDelete(perform: notesStore.delete)
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New") {
                        router.noteToOpen = nil
                        router.selectedTab = .paste
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
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
    @State private var showingDefinition = false

    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil
    @State private var segVM: SegmentedTextViewModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                NavigationLink("Extract Words") {
                    ExtractWordsView(text: editableText.isEmpty ? note.text : editableText)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }

            TextField("Title", text: $editableTitle)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.roundedBorder)

            FuriganaTextEditor(text: $editableText, showFurigana: showFurigana, isEditable: !showFurigana && isEditing, allowTokenTap: !isEditing) { token in
                selectedToken = token
                showingDefinition = true
                Task {
                    await lookupDefinitions(for: token)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)

            if let segVM {
                SegmentedTextView(viewModel: segVM)
                    .onChange(of: segVM.selected) { _, newSelected in
                        guard let selected = newSelected else { return }
                        let token = ParsedToken(surface: selected.surface, reading: "", meaning: "")
                        selectedToken = token
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
                                store.add(surface: surface, reading: first.reading, meaning: firstGloss)
                            } else {
                                // Fallback: attempt to add the tapped token if it already has a meaning; otherwise WordStore.add will ignore empty meanings
                                let fallbackMeaning = token.meaning ?? ""
                                store.add(surface: token.surface, reading: token.reading, meaning: fallbackMeaning)
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
            if let trie = JMdictTrieCache.shared {
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

