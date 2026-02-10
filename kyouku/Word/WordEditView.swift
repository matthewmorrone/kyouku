import SwiftUI

struct WordEditView: View {
    @EnvironmentObject private var store: WordsStore
    @Environment(\.dismiss) private var dismiss

    let wordID: Word.ID

    @State private var surface: String = ""
    @State private var dictionarySurface: String = ""
    @State private var kana: String = ""
    @State private var meaning: String = ""
    @State private var note: String = ""

    @State private var selectedListIDs: Set<UUID> = []
    @State private var newListName: String = ""

    @State private var isLoadingAutofill: Bool = false
    @State private var errorMessage: String? = nil

    private var word: Word? {
        store.words.first(where: { $0.id == wordID })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Saved Entry") {
                    TextField("Surface (kanji/kana)", text: $surface)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    TextField("Dictionary surface (optional)", text: $dictionarySurface)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    TextField("Kana (reading)", text: $kana)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    TextField("Meaning (English)", text: $meaning, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(false)
                        .lineLimit(2...6)

                    TextField("Note (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("Autofill") {
                    Button {
                        Task { await autofill(onlyMissing: true) }
                    } label: {
                        HStack {
                            Text("Autofill Missing Fields")
                            Spacer()
                            if isLoadingAutofill { ProgressView() }
                        }
                    }
                    .disabled(isLoadingAutofill)

                    Button {
                        Task { await autofill(onlyMissing: false) }
                    } label: {
                        HStack {
                            Text("Autofill (Overwrite)")
                            Spacer()
                            if isLoadingAutofill { ProgressView() }
                        }
                    }
                    .disabled(isLoadingAutofill)
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
                            createListFromEditor()
                        }
                        .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        store.delete(id: wordID)
                        dismiss()
                    } label: {
                        Label("Delete Word", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Edit Word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                loadFromStore()
            }
            .onReceive(store.$lists) { lists in
                let valid = Set(lists.map { $0.id })
                selectedListIDs.formIntersection(valid)
            }
        }
    }

    private func loadFromStore() {
        guard let word else { return }
        surface = word.surface
        dictionarySurface = word.dictionarySurface ?? ""
        kana = word.kana ?? ""
        meaning = word.meaning
        note = word.note ?? ""
        selectedListIDs = Set(word.listIDs)
    }

    private func saveChanges() {
        errorMessage = nil

        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false else {
            errorMessage = "Surface is required."
            return
        }

        let dsTrim = dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds: String? = dsTrim.isEmpty ? nil : dsTrim

        let kTrim = kana.trimmingCharacters(in: .whitespacesAndNewlines)
        let k: String? = kTrim.isEmpty ? nil : kTrim

        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let nTrim = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let n: String? = nTrim.isEmpty ? nil : nTrim

        store.update(
            id: wordID,
            surface: s,
            dictionarySurface: ds,
            kana: k,
            meaning: m,
            note: n
        )

        store.setLists(forWordID: wordID, listIDs: Array(selectedListIDs))

        dismiss()
    }

    private func toggleList(_ id: UUID) {
        if selectedListIDs.contains(id) {
            selectedListIDs.remove(id)
        } else {
            selectedListIDs.insert(id)
        }
    }

    private func createListFromEditor() {
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

    private func autofill(onlyMissing: Bool) async {
        await MainActor.run {
            isLoadingAutofill = true
            errorMessage = nil
        }
        defer {
            Task { @MainActor in
                isLoadingAutofill = false
            }
        }

        // Candidates: dictionary surface, surface, kana.
        var candidates: [String] = []
        let ds = dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines)
        if ds.isEmpty == false { candidates.append(ds) }
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty == false { candidates.append(s) }
        let k = kana.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty == false { candidates.append(k) }

        // Dedupe preserving order.
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }

        do {
            var found: DictionaryEntry? = nil
            for cand in candidates {
                let keys = DictionaryKeyPolicy.keys(forDisplayKey: cand)
                guard keys.lookupKey.isEmpty == false else { continue }
                let rows = try await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 1)
                if let first = rows.first {
                    found = first
                    break
                }
            }

            guard let entry = found else {
                await MainActor.run {
                    errorMessage = "No dictionary match found for autofill."
                }
                return
            }

            let proposedSurface = entry.kanji.isEmpty ? (entry.kana ?? "") : entry.kanji
            let proposedDictionarySurface = proposedSurface
            let proposedKana = entry.kana ?? (entry.kanji.isEmpty ? nil : nil)
            let proposedMeaning = firstGloss(entry.gloss)

            await MainActor.run {
                if onlyMissing {
                    if surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposedSurface.isEmpty == false {
                        surface = proposedSurface
                    }
                    if dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposedDictionarySurface.isEmpty == false {
                        dictionarySurface = proposedDictionarySurface
                    }
                    if kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let proposedKana, proposedKana.isEmpty == false {
                        kana = proposedKana
                    }
                    if meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposedMeaning.isEmpty == false {
                        meaning = proposedMeaning
                    }
                } else {
                    if proposedSurface.isEmpty == false { surface = proposedSurface }
                    dictionarySurface = proposedDictionarySurface
                    if let proposedKana, proposedKana.isEmpty == false { kana = proposedKana }
                    meaning = proposedMeaning
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Autofill failed: \(error.localizedDescription)"
            }
        }
    }

    private func firstGloss(_ gloss: String) -> String {
        gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? gloss
    }
}
