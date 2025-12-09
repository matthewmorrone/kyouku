//
//  NotesView.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//


//
//  NotesView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI
import Combine

struct NotesView: View {
    @EnvironmentObject var notes: NotesStore

    var body: some View {
        NavigationStack {
            List {
                ForEach(notes.notes) { note in
                    NavigationLink(value: note) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notePreview(note.text))
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

    // Show the first line of the note as the preview
    private func notePreview(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}

//
//  Detail View for a Single Note
//

struct NoteDetailView: View {
    let note: Note

    var body: some View {
        ScrollView {
            Text(note.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
    }
}
