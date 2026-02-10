import SwiftUI

struct WordListAssignmentSheet: View {
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

struct ComponentPreviewSheet: View {
    let part: WordDefinitionsView.TokenPart
    let onOpenFullPage: (WordDefinitionsView.TokenPart) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var lookupViewModel = DictionaryLookupViewModel()

    private var displayKana: String? {
        let trimmed = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false, trimmed != part.surface else { return nil }
        return trimmed
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(part.surface)
                                .font(.title2.weight(.semibold))
                            if let displayKana {
                                Text(displayKana)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }

                        if let first = lookupViewModel.results.first, first.gloss.isEmpty == false {
                            Text(first.gloss)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if lookupViewModel.isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let error = lookupViewModel.errorMessage, error.isEmpty == false {
                    Section {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                } else if lookupViewModel.results.isEmpty {
                    Section {
                        Text("No matches.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Top matches") {
                        ForEach(Array(lookupViewModel.results.prefix(5))) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.kanji)
                                        .font(.body.weight(.semibold))
                                    if let kana = entry.kana, kana.isEmpty == false, kana != entry.kanji {
                                        Text(kana)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                if entry.gloss.isEmpty == false {
                                    Text(entry.gloss)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open full page") {
                        dismiss()
                        DispatchQueue.main.async {
                            onOpenFullPage(part)
                        }
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .task(id: part.id) {
                await lookupViewModel.lookup(term: part.surface, mode: .japanese)
                if lookupViewModel.results.isEmpty, let kana = part.kana, kana.isEmpty == false, kana != part.surface {
                    await lookupViewModel.lookup(term: kana, mode: .japanese)
                }
            }
        }
    }
}
