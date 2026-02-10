import SwiftUI

struct WordListsManagerView: View {
    @EnvironmentObject private var store: WordsStore
    @Environment(\.dismiss) private var dismiss

    @State private var newListName: String = ""
    @State private var editingList: WordList? = nil

    var body: some View {
        List {
            Section("Create") {
                HStack(spacing: 12) {
                    TextField("List name", text: $newListName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                    Button("Add") {
                        if store.createList(name: newListName) != nil {
                            newListName = ""
                        }
                    }
                    .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Lists") {
                if store.lists.isEmpty {
                    Text("No lists yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.lists) { list in
                        HStack {
                            Text(list.name)
                            Spacer()
                            Text("\(store.wordCount(inList: list.id))")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingList = list
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.deleteList(id: list.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(item: $editingList) { list in
            NavigationStack {
                WordListEditView(list: list)
            }
        }
    }
}

struct WordListEditView: View {
    @EnvironmentObject private var store: WordsStore
    @Environment(\.dismiss) private var dismiss

    let list: WordList
    @State private var name: String

    init(list: WordList) {
        self.list = list
        _name = State(initialValue: list.name)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("List name", text: $name)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
            }
        }
        .navigationTitle("Edit List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    store.renameList(id: list.id, name: name)
                    dismiss()
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
