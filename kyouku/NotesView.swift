//
//  NotesView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI

struct NotesView: View {
    @EnvironmentObject var notes: NotesStore
    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(notes.notes) { note in
                    NavigationLink(value: note) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rowTitle(for: note))
                                .font(.headline)
                                .lineLimit(1)

                            Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .onDelete(perform: notes.deleteNote)
            }
            .navigationTitle("Notes")
            .navigationDestination(for: Note.self) { note in
                NoteDetailView(note: note)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
    }

    private func rowTitle(for note: Note) -> String {
        if let title = note.title, !title.isEmpty {
            return title
        } else {
            return notePreview(note.text)
        }
    }

    private func notePreview(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}

//
//struct NotesView: View {
//    @EnvironmentObject var notesStore: NotesStore
//
//    var body: some View {
//        NavigationStack {
//            List {
//                if notesStore.notes.isEmpty {
//                    VStack(alignment: .leading, spacing: 8) {
//                        Text("No notes yet")
//                            .font(.headline)
//                        Text("Paste text, then tap the save icon to create a note.")
//                            .font(.subheadline)
//                            .foregroundStyle(.secondary)
//                    }
//                    .padding(.vertical, 8)
//                } else {
//                    ForEach(notesStore.notes) { note in
//                        NavigationLink(value: note) {
//                            VStack(alignment: .leading, spacing: 6) {
//                                Text(note.title?.isEmpty == false ? note.title! : "Untitled")
//                                    .font(.headline)
//
//                                Text(note.text)
//                                    .font(.subheadline)
//                                    .foregroundStyle(.secondary)
//                                    .lineLimit(3)
//                            }
//                            .padding(.vertical, 4)
//                        }
//                    }
//                    .onDelete(perform: notesStore.delete)
//                }
//            }
//            .navigationTitle("Notes")
//            .navigationDestination(for: Note.self) { note in
//                ScrollView {
//                    VStack(alignment: .leading, spacing: 12) {
//                        Text(note.title?.isEmpty == false ? note.title! : "Untitled")
//                            .font(.title3)
//                            .bold()
//
//                        Text(note.text)
//                            .textSelection(.enabled)
//                            .frame(maxWidth: .infinity, alignment: .leading)
//                    }
//                    .padding()
//                }
//                .navigationTitle("Note")
//                .navigationBarTitleDisplayMode(.inline)
//            }
//            .toolbar {
//                ToolbarItem(placement: .topBarTrailing) {
//                    EditButton()
//                }
//            }
//        }
//    }
//}
//
//
//  Detail View for a Single Note
//

struct NoteDetailView: View {
    @EnvironmentObject var store: WordStore
    @EnvironmentObject var notesStore: NotesStore
    let note: Note

    @State private var showFurigana = true

    @State private var editableTitle: String = ""
    @State private var editableText: String = ""

    @State private var selectedToken: ParsedToken? = nil
    @State private var showingDefinition = false

    @State private var dictResults: [DictionaryEntry] = []
    @State private var isLookingUp = false
    @State private var lookupError: String? = nil

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

            FuriganaTextEditor(text: $editableText, showFurigana: showFurigana) { token in
                selectedToken = token
                showingDefinition = true
                Task {
                    await lookupDefinitions(for: token)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFurigana.toggle()
                } label: {
                    Image(systemName: showFurigana ? "textformat" : "textformat.size.smaller")
                }
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
                }
            }
        }
        .sheet(isPresented: $showingDefinition) {
            if let token = selectedToken {
                VStack(alignment: .leading, spacing: 12) {
                    Text(token.surface)
                        .font(.title2).bold()
                    if !token.reading.isEmpty {
                        Text("Reading: \(token.reading)")
                            .font(.headline)
                    }
                    if isLookingUp {
                        ProgressView("Looking up definitions…")
                    } else if let err = lookupError {
                        Text(err).foregroundStyle(.secondary)
                    } else if dictResults.isEmpty {
                        Text("No definitions found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dictResults, id: \.id) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.kanji.isEmpty ? entry.reading : entry.kanji)
                                        .font(.headline)
                                    if !entry.reading.isEmpty && entry.reading != entry.kanji {
                                        Text("【\(entry.reading)】")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(entry.gloss)
                                    .font(.body)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    HStack {
                        Button("Add to Words") {
                            if let token = selectedToken, !store.words.contains(where: { $0.surface == token.surface && $0.reading == token.reading }) {
                                store.add(from: token)
                            }
                            showingDefinition = false
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Close") { showingDefinition = false }
                    }
                }
                .padding()
                .presentationDetents([.medium, .large])
            } else {
                Text("No selection")
                    .padding()
            }
        }
        .onAppear {
            editableTitle = note.title ?? ""
            editableText = note.text
        }
    }

    private func lookupDefinitions(for token: ParsedToken) async {
        await MainActor.run {
            isLookingUp = true
            lookupError = nil
            dictResults = []
        }
        do {
            var results = try await DictionarySQLiteStore.shared.lookup(term: token.surface)
            if results.isEmpty && !token.reading.isEmpty {
                let alt = try await DictionarySQLiteStore.shared.lookup(term: token.reading)
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

