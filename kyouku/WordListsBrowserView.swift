import SwiftUI

struct WordListsBrowserView: View {
    @EnvironmentObject private var store: WordsStore
    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedFilter: WordsListFilter
    @State private var cachedNoteListItems: [NoteListItem] = []
    @State private var cachedListCounts: [UUID: Int] = [:]
    @State private var noteTitlesByID: [UUID: String] = [:]

    private struct NoteListItem: Identifiable, Hashable {
        let id: UUID
        let title: String
        let count: Int
    }

    private func refreshNoteListItems() {
        let entries = buildSortedNoteCountEntries(from: store.words, titleFor: title(forNoteID:))
        cachedNoteListItems = entries.map { entry in
            NoteListItem(id: entry.noteID, title: entry.title, count: entry.count)
        }
    }

    private func refreshNoteTitleCache() {
        noteTitlesByID = buildNoteTitlesByID(from: notesStore.notes, maxDerivedTitleLength: 42)
    }

    private func refreshListCounts() {
        var counts: [UUID: Int] = [:]
        for word in store.words {
            for listID in word.listIDs {
                counts[listID, default: 0] += 1
            }
        }
        cachedListCounts = counts
    }

    private func title(forNoteID id: UUID) -> String? {
        noteTitlesByID[id]
    }

    var body: some View {
        List {
            Section {
                Button {
                    selectedFilter = .all
                    dismiss()
                } label: {
                    HStack {
                        Text("All Words")
                        Spacer()
                        Text("\(store.words.count)")
                            .foregroundStyle(.secondary)
                        if selectedFilter.isAll {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            if store.lists.isEmpty == false {
                Section("Saved Lists") {
                    ForEach(store.lists) { list in
                        Button {
                            selectedFilter = .list(list.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(list.name)
                                Spacer()
                                Text("\(cachedListCounts[list.id] ?? 0)")
                                    .foregroundStyle(.secondary)
                                if selectedFilter == .list(list.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if cachedNoteListItems.isEmpty == false {
                Section("Notes") {
                    ForEach(cachedNoteListItems) { item in
                        Button {
                            selectedFilter = .note(item.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(item.title)
                                Spacer()
                                Text("\(item.count)")
                                    .foregroundStyle(.secondary)
                                if selectedFilter == .note(item.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    WordListsManagerView()
                } label: {
                    Label("Manage Saved Lists", systemImage: "folder.badge.gear")
                }
            }
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshNoteTitleCache()
            refreshNoteListItems()
            refreshListCounts()
        }
        .onReceive(store.$words) { _ in
            refreshNoteListItems()
            refreshListCounts()
        }
        .onReceive(notesStore.$notes) { _ in
            refreshNoteTitleCache()
            refreshNoteListItems()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}
