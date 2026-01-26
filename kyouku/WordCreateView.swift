import SwiftUI

struct WordCreateView: View {
    @EnvironmentObject private var store: WordsStore
    @Environment(\.dismiss) private var dismiss

    let initialSurface: String

    @State private var surface: String
    @State private var dictionarySurface: String
    @State private var kana: String
    @State private var meaning: String
    @State private var note: String

    private enum ListSelection: Hashable {
        case none
        case existing(UUID)
        case createNew
    }

    @State private var listSelection: ListSelection = .none
    @State private var lastNonCreateListSelection: ListSelection = .none
    @State private var isPromptingForNewListName: Bool = false
    @State private var pendingNewListName: String = ""

    @State private var isLoadingAutofill: Bool = false
    @State private var errorMessage: String? = nil

    @State private var autofillDebounceTask: Task<Void, Never>? = nil
    @State private var autofillInFlightTask: Task<Void, Never>? = nil
    @State private var pendingAutofillSignature: String = ""

    init(initialSurface: String = "") {
        self.initialSurface = initialSurface
        _surface = State(initialValue: initialSurface)
        _dictionarySurface = State(initialValue: "")
        _kana = State(initialValue: "")
        _meaning = State(initialValue: "")
        _note = State(initialValue: "")
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

                    if isLoadingAutofill {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Autofilling…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Add to list") {
                    Picker("List", selection: $listSelection) {
                        Text("None").tag(ListSelection.none)

                        if store.lists.isEmpty == false {
                            ForEach(store.lists) { list in
                                Text(list.name).tag(ListSelection.existing(list.id))
                            }
                        }

                        Divider()
                        Text("Create a new list…").tag(ListSelection.createNew)
                    }
                    .pickerStyle(.menu)
                }
            }
            .navigationTitle("New Word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveNewWord()
                    }
                    .disabled(surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onReceive(store.$lists) { lists in
                let valid = Set(lists.map { $0.id })
                if case let .existing(id) = listSelection, valid.contains(id) == false {
                    listSelection = .none
                }
            }
            .onChange(of: listSelection) { oldValue, newValue in
                if case .createNew = newValue {
                    // Prompt immediately, then update selection to the created list.
                    pendingNewListName = ""
                    isPromptingForNewListName = true
                } else {
                    lastNonCreateListSelection = newValue
                }
            }
            .onChange(of: surface) { _, _ in
                scheduleAutofillIfNeeded()
            }
            .onChange(of: dictionarySurface) { _, _ in
                scheduleAutofillIfNeeded()
            }
            .onChange(of: kana) { _, _ in
                scheduleAutofillIfNeeded()
            }
            .alert("New List", isPresented: $isPromptingForNewListName) {
                TextField("List name", text: $pendingNewListName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)

                Button("Cancel", role: .cancel) {
                    pendingNewListName = ""
                    // Revert selection back to the last stable choice.
                    listSelection = lastNonCreateListSelection
                }

                Button("Save") {
                    createListAndSelectIt()
                }
                .disabled(pendingNewListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("Enter a name for the new list.")
            }
        }
    }

    private func saveNewWord() {
        errorMessage = nil

        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false else {
            errorMessage = "Surface is required."
            return
        }

        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard m.isEmpty == false else {
            errorMessage = "Meaning is required."
            return
        }

        let dsTrim = dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds: String? = dsTrim.isEmpty ? nil : dsTrim

        let kTrim = kana.trimmingCharacters(in: .whitespacesAndNewlines)
        let k: String? = kTrim.isEmpty ? nil : kTrim

        let nTrim = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let n: String? = nTrim.isEmpty ? nil : nTrim

        switch listSelection {
        case .createNew:
            // Should be rare (prompt is immediate), but be defensive.
            store.add(
                surface: s,
                dictionarySurface: ds,
                kana: k,
                meaning: m,
                note: n,
                sourceNoteID: nil,
                listIDs: []
            )
            dismiss()
        case .none:
            store.add(
                surface: s,
                dictionarySurface: ds,
                kana: k,
                meaning: m,
                note: n,
                sourceNoteID: nil,
                listIDs: []
            )
            dismiss()
        case .existing(let id):
            store.add(
                surface: s,
                dictionarySurface: ds,
                kana: k,
                meaning: m,
                note: n,
                sourceNoteID: nil,
                listIDs: [id]
            )
            dismiss()
        }
    }

    private func createListAndSelectIt() {
        let name = pendingNewListName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else { return }

        let listID: UUID
        if let existing = store.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            listID = existing.id
        } else if let created = store.createList(name: name) {
            listID = created.id
        } else if let existing = store.lists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            listID = existing.id
        } else {
            errorMessage = "Couldn't create list. Try a different name."
            return
        }

        listSelection = .existing(listID)
        lastNonCreateListSelection = .existing(listID)
        pendingNewListName = ""
        isPromptingForNewListName = false
    }

    private func scheduleAutofillIfNeeded() {
        // Only fill missing fields; never overwrite user edits.
        let needsMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsKana = kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsDictionarySurface = dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard needsMeaning || needsKana || needsDictionarySurface else { return }

        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds = dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana.trimmingCharacters(in: .whitespacesAndNewlines)

        // Avoid autofilling off of extremely short kana (e.g. "た"), which can match many entries.
        let kanaCandidateIsUsable = (k.isEmpty || k.count >= 2)
        guard kanaCandidateIsUsable else { return }

        // Need at least one usable candidate.
        guard s.isEmpty == false || ds.isEmpty == false || k.isEmpty == false else { return }

        let signature = "s=\(s)|ds=\(ds)|k=\(k)"
        pendingAutofillSignature = signature

        autofillDebounceTask?.cancel()
        autofillDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard Task.isCancelled == false else { return }
            await requestAutofillIfLatest(signature: signature)
        }
    }

    @MainActor
    private func requestAutofillIfLatest(signature: String) async {
        // If the user typed more since this task was scheduled, drop it.
        guard pendingAutofillSignature == signature else { return }

        // If an autofill is already running, re-run after it completes.
        if autofillInFlightTask != nil {
            let latest = pendingAutofillSignature
            autofillDebounceTask?.cancel()
            autofillDebounceTask = Task {
                // Wait for the in-flight autofill to finish.
                while true {
                    let stillRunning = await MainActor.run { autofillInFlightTask != nil }
                    if stillRunning == false { break }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if Task.isCancelled { return }
                }
                await requestAutofillIfLatest(signature: latest)
            }
            return
        }

        autofillInFlightTask = Task {
            await autofill(onlyMissing: true)
            await MainActor.run {
                autofillInFlightTask = nil
            }
        }
        _ = await autofillInFlightTask?.value
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

        var candidates: [String] = []
        let ds = dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines)
        if ds.isEmpty == false { candidates.append(ds) }
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty == false { candidates.append(s) }
        let k = kana.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty == false { candidates.append(k) }

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
            let proposedKana = entry.kana
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
