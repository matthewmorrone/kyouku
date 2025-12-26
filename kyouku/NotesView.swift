//
//  NotesView.swift
//  Otokoto
//
//  Created by Matthew Morrone on 12/7/25.
//

import SwiftUI
import UIKit

struct NotesView: View {
    @EnvironmentObject var notesStore: NotesStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var store: WordsStore
    @State private var pendingDeleteOffsets: IndexSet? = nil
    @State private var showDeleteAlert: Bool = false
    @State private var pendingDeleteHasAssociatedWords: Bool = false
    @State private var editModeState: EditMode = .inactive
    @State private var showRenameAlert: Bool = false
    @State private var renameTarget: Note? = nil
    @State private var renameText: String = ""

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
                                Text((note.title?.isEmpty == false ? note.title! : "Untitled") as String)
                                    .font(.headline)

                                Text(note.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 4)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = note.text
                            } label: {
                                Label("Copy Text", systemImage: "doc.on.doc")
                            }
                            Button {
                                // Duplicate note: insert a copy at the top and save
                                let copy = Note(id: UUID(), title: note.title, text: note.text, createdAt: Date())
                                notesStore.notes.insert(copy, at: 0)
                                notesStore.save()
                            } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Button {
                                // Reset custom spans (reading overrides) for this note
                                NotificationCenter.default.post(name: .readingOverridesRequestRemoveAllForNote, object: nil, userInfo: ["noteID": note.id])
                            } label: {
                                Label("Reset Custom Spans", systemImage: "arrow.counterclockwise")
                            }
                            // Divider()

                            Button {
                                presentRenameAlert(for: note)
                            } label: {
                                Label("Rename", systemImage: "text.cursor")
                            }
                            Button {
                                router.noteToOpen = note
                                router.pasteShouldBeginEditing = true
                                router.selectedTab = .paste
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                    // Trigger existing delete flow by setting pending offsets for this single note
                                if let index = notesStore.notes.firstIndex(where: { $0.id == note.id }) {
                                    pendingDeleteOffsets = IndexSet(integer: index)
                                    let noteID = notesStore.notes[index].id
                                    pendingDeleteHasAssociatedWords = store.words.contains { $0.sourceNoteID == noteID }
                                    showDeleteAlert = true
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
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
            .environment(\.editMode, $editModeState)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { PasteView.createNewNote(notes: notesStore, router: router) }) {
                        Image(systemName: "plus.square")
                            .font(.title2)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            if editModeState.isEditing {
                                editModeState = .inactive
                            } else {
                                editModeState = .active
                            }
                        }
                    } label: {
                        Image(systemName: "pencil.line")
                            .font(.title2)
                    }
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
            .alert("Rename Note", isPresented: $showRenameAlert, presenting: renameTarget) { note in
                TextField("Title", text: $renameText)
                Button("Save") {
                    commitRename(note, title: renameText)
                }
                Button("Cancel", role: .cancel) {
                    resetRenameState()
                }
            } message: { _ in
                Text("Enter a new title for this note.")
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

    private func presentRenameAlert(for note: Note) {
        renameTarget = note
        renameText = note.title ?? ""
        showRenameAlert = true
    }

    private func commitRename(_ note: Note, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = note
        updated.title = trimmed.isEmpty ? nil : trimmed
        notesStore.updateNote(updated)
        resetRenameState()
    }

    private func resetRenameState() {
        renameTarget = nil
        renameText = ""
        showRenameAlert = false
    }
}

extension Notification.Name {
    static let readingOverridesRequestRemoveAllForNote = Notification.Name("readingOverridesRequestRemoveAllForNote")
}

