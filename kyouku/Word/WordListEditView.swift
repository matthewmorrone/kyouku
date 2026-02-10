import SwiftUI

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

