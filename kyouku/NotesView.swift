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
    @EnvironmentObject var store: WordsStore
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


