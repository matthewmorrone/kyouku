import SwiftUI
import UIKit

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

    // Autofill should keep updating while the user types, but once the user edits
    // English manually (including clearing it), we should never “snap back”.
    @State private var isApplyingAutofill: Bool = false
    @State private var meaningAutofillEnabled: Bool = true

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
                    PreferredLanguageTextField(
                        placeholder: "Kanji",
                        text: $surface,
                        preferredLanguagePrefixes: ["ja"],
                        autocorrectionDisabled: true,
                        autocapitalization: .none
                    )

                    PreferredLanguageTextField(
                        placeholder: "Kana",
                        text: $kana,
                        preferredLanguagePrefixes: ["ja"],
                        autocorrectionDisabled: true,
                        autocapitalization: .none
                    )

                    PreferredLanguageTextField(
                        placeholder: "English",
                        text: $meaning,
                        preferredLanguagePrefixes: ["en"],
                        autocorrectionDisabled: false,
                        autocapitalization: .none
                    )

                    PreferredLanguageTextField(
                        placeholder: "Note (optional)",
                        text: $note,
                        preferredLanguagePrefixes: ["en", "ja"],
                        autocorrectionDisabled: false,
                        autocapitalization: .sentences
                    )

                    /*
                    if isLoadingAutofill {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Autofilling…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    */
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
                    .disabled((surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .onChange(of: kana) { _, _ in
                scheduleAutofillIfNeeded()
            }
            .onChange(of: meaning) { _, _ in
                // If the user touches English, stop autofilling it forever.
                if isApplyingAutofill == false {
                    meaningAutofillEnabled = false
                }
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

        var headword = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        var reading = kana.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the user only provided Kana, treat that as the headword.
        if headword.isEmpty, reading.isEmpty == false {
            headword = reading
            reading = ""
        }

        // Avoid storing redundant kana equal to the headword.
        if reading == headword {
            reading = ""
        }

        let s = headword
        guard s.isEmpty == false else {
            errorMessage = "Kanji or Kana is required."
            return
        }

        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard m.isEmpty == false else {
            errorMessage = "Meaning is required."
            return
        }

        let dsTrim = dictionarySurface.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds: String? = dsTrim.isEmpty ? nil : dsTrim

        let k: String? = reading.isEmpty ? nil : reading

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
        // Autofill should:
        // - keep updating English while typing, until the user edits English
        // - fill missing Kanji/Kana when possible
        let needsMeaning = meaningAutofillEnabled
        let needsSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let needsKana = kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard needsMeaning || needsSurface || needsKana else { return }

        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana.trimmingCharacters(in: .whitespacesAndNewlines)

        // Avoid autofilling off of extremely short kana (e.g. "た"), which can match many entries.
        let kanaCandidateIsUsable = (k.isEmpty || k.count >= 2)
        guard kanaCandidateIsUsable else { return }

        // If surface is kana-only, apply the same short-candidate rule.
        let surfaceCandidateIsUsable = (s.isEmpty || looksLikeKanaOnly(s) == false || s.count >= 2)
        guard surfaceCandidateIsUsable else { return }

        // Need at least one usable candidate.
        guard s.isEmpty == false || k.isEmpty == false else { return }

        // Signature should be based on user inputs only, not derived/autofilled state.
        let signature = "s=\(s)|k=\(k)"
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
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer Kana if the user provided it.
        if k.isEmpty == false { candidates.append(k) }
        if s.isEmpty == false { candidates.append(s) }

        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0).inserted }

        do {
            var found: DictionaryEntry? = nil
            for cand in candidates {
                let keys = DictionaryKeyPolicy.keys(forDisplayKey: cand)
                guard keys.lookupKey.isEmpty == false else { continue }
                let rows = try await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 20)
                if let best = bestAutofillMatch(in: rows, forQuery: keys.lookupKey) {
                    found = best
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
                isApplyingAutofill = true
                defer { isApplyingAutofill = false }

                if onlyMissing {
                    if surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, proposedSurface.isEmpty == false {
                        surface = proposedSurface
                    }
                    if proposedDictionarySurface.isEmpty == false {
                        dictionarySurface = proposedDictionarySurface
                    }
                    if kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let proposedKana, proposedKana.isEmpty == false {
                        kana = proposedKana
                    }
                    if meaningAutofillEnabled, proposedMeaning.isEmpty == false {
                        meaning = proposedMeaning
                    }
                } else {
                    if proposedSurface.isEmpty == false { surface = proposedSurface }
                    dictionarySurface = proposedDictionarySurface
                    if let proposedKana, proposedKana.isEmpty == false { kana = proposedKana }
                    if meaningAutofillEnabled {
                        meaning = proposedMeaning
                    }
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Autofill failed: \(error.localizedDescription)"
            }
        }
    }

    private func looksLikeKanaOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }

        for scalar in trimmed.unicodeScalars {
            // Allow the long vowel mark and common punctuation used in kana words.
            if scalar == "ー" || scalar == "・" { continue }

            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F: // Half-width katakana
                continue
            default:
                return false
            }
        }
        return true
    }

    private func bestAutofillMatch(in rows: [DictionaryEntry], forQuery query: String) -> DictionaryEntry? {
        guard rows.isEmpty == false else { return nil }

        func lcp(_ a: String, _ b: String) -> Int {
            let ascalars = Array(a.unicodeScalars)
            let bscalars = Array(b.unicodeScalars)
            let n = min(ascalars.count, bscalars.count)
            var i = 0
            while i < n {
                if ascalars[i] != bscalars[i] { break }
                i += 1
            }
            return i
        }

        func scoreSurface(_ surface: String, query: String) -> (rank: Int, lcp: Int, diff: Int) {
            let l = lcp(surface, query)

            if surface == query {
                return (0, l, 0)
            }
            if surface.hasPrefix(query) {
                return (1, l, abs(surface.count - query.count))
            }
            if query.hasPrefix(surface) {
                return (2, l, abs(surface.count - query.count))
            }
            if surface.contains(query) {
                return (3, l, abs(surface.count - query.count))
            }
            return (4, l, abs(surface.count - query.count))
        }

        var best: (entry: DictionaryEntry, score: (Int, Int, Int))? = nil
        for entry in rows {
            var surfaces: [String] = []
            if entry.kanji.isEmpty == false {
                surfaces.append(entry.kanji)
            }
            if let k = entry.kana, k.isEmpty == false {
                surfaces.append(k)
            }
            if surfaces.isEmpty {
                continue
            }

            let bestSurfaceScore = surfaces
                .map { scoreSurface($0, query: query) }
                .min { a, b in
                    if a.rank != b.rank { return a.rank < b.rank }
                    if a.lcp != b.lcp { return a.lcp > b.lcp }
                    return a.diff < b.diff
                }!

            let tupleScore: (Int, Int, Int) = (bestSurfaceScore.rank, -bestSurfaceScore.lcp, bestSurfaceScore.diff)
            if let current = best {
                if tupleScore < current.score {
                    best = (entry, tupleScore)
                }
            } else {
                best = (entry, tupleScore)
            }
        }

        return best?.entry ?? rows.first
    }

    private func firstGloss(_ gloss: String) -> String {
        gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? gloss
    }
}
