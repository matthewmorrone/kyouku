import SwiftUI

struct WordListsAssignmentSheet: View {
    @EnvironmentObject var store: WordsStore
    @Environment(\.dismiss) private var dismiss

    let wordID: Word.ID
    let title: String

    @State var selectedListIDs: Set<UUID> = []
    @State var newListName: String = ""

    private var word: Word? {
        store.words.first(where: { $0.id == wordID })
    }

    var body: some View {
        List {
            Section {
                Text(title)
                    .font(.headline)
            }

            Section("Lists") {
                if store.lists.isEmpty {
                    Text("No lists yet. Create one below.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.lists) { list in
                        Button {
                            toggleList(list.id)
                        } label: {
                            HStack {
                                Text(list.name)
                                Spacer()
                                if selectedListIDs.contains(list.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 12) {
                    TextField("New list name", text: $newListName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                    Button("Add") {
                        createListFromSheet()
                    }
                    .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    store.setLists(forWordID: wordID, listIDs: Array(selectedListIDs))
                    dismiss()
                }
                .disabled(word == nil)
            }
        }
        .task {
            if let word {
                selectedListIDs = Set(word.listIDs)
            }
        }
        .onReceive(store.$lists) { lists in
            let valid = Set(lists.map { $0.id })
            selectedListIDs.formIntersection(valid)
        }
    }

    private func toggleList(_ id: UUID) {
        if selectedListIDs.contains(id) {
            selectedListIDs.remove(id)
        } else {
            selectedListIDs.insert(id)
        }
    }

    private func createListFromSheet() {
        let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }

        if let existing = store.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            selectedListIDs.insert(existing.id)
            newListName = ""
            return
        }

        if let created = store.createList(name: name) {
            selectedListIDs.insert(created.id)
            newListName = ""
        }
    }
}

