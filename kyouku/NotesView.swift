//
//  NotesView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI

struct NotesView: View {
    @EnvironmentObject var notes: NotesStore

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
    let note: Note

    @State private var showTokens = false
    @State private var tokens: [ParsedToken] = []

    @State private var showFurigana = true
    @State private var attributedText: NSAttributedString = NSAttributedString(string: "")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // NOTE TEXT WITH OPTIONAL FURIGANA
                FuriganaTextView(attributedText: attributedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)

                // EXTRACT BUTTON
                Button(showTokens ? "Hide Extracted Words" : "Extract Words") {
                    if !showTokens {
                        tokens = JapaneseParser.parse(text: note.text)
                    }
                    showTokens.toggle()
                }
                .buttonStyle(.borderedProminent)

                // INLINE TOKEN LIST
                if showTokens {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(tokens) { token in
                            Button {
                                store.add(from: token)
                            } label: {
                                FuriganaTextView(token: token)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 12)
                }

                Spacer(minLength: 40)
            }
            .padding()
        }
        .navigationTitle(note.title?.isEmpty == false ? note.title! : "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFurigana.toggle()
                    rebuildAttributedText()
                } label: {
                    Image(systemName: showFurigana ? "textformat" : "textformat.size.smaller")
                }
            }
        }
        .onAppear {
            rebuildAttributedText()
        }
    }

    private func rebuildAttributedText() {
        attributedText = JapaneseFuriganaBuilder.buildAttributedText(
            text: note.text,
            showFurigana: showFurigana
        )
    }
}
