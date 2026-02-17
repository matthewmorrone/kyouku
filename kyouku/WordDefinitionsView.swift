import SwiftUI
import UIKit

struct WordDefinitionView: View {
    @EnvironmentObject private var store: WordsStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.dismiss) private var dismiss

    let request: Request

    @State private var snapshot: Snapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isPromptingForNewListName: Bool = false
    @State private var pendingNewListName: String = ""
    @State private var exampleNavigationTarget: ExampleNavigationTarget?
    @State private var activeExampleTokenPreview: ExampleTokenPreview?

    private struct ExampleNavigationTarget: Identifiable, Hashable {
        let id = UUID()
        let surface: String
    }

    private struct ExampleTokenPreview: Identifiable {
        let id = UUID()
        let surface: String
        let reading: String?
        let gloss: String?
    }

    struct ListOption: Identifiable {
        let id: UUID
        let name: String
        let isSelected: Bool
    }

    struct Request: Identifiable, Hashable {
        let id: UUID
        let term: Term
        let context: Context
        let metadata: Metadata

        struct Term: Hashable {
            let surface: String
            let kana: String?
        }

        struct Context: Hashable {
            let sentence: String?
            let lemmaCandidates: [String]
            let tokenPartOfSpeech: String?
            let tokenParts: [TokenPart]
        }

        struct Metadata: Hashable {
            let sourceNoteID: UUID?
        }

        init(
            id: UUID = UUID(),
            term: Term,
            context: Context = Context(sentence: nil, lemmaCandidates: [], tokenPartOfSpeech: nil, tokenParts: []),
            metadata: Metadata = Metadata(sourceNoteID: nil)
        ) {
            self.id = id
            self.term = term
            self.context = context
            self.metadata = metadata
        }
    }

    struct TokenPart: Identifiable, Hashable {
        let id: String
        let surface: String
        let kana: String?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if let errorMessage, errorMessage.isEmpty == false {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let snapshot {
                    SectionCard {
                        HeaderSection(
                            snapshot: snapshot,
                            listOptions: listOptions(for: snapshot),
                            onSpeak: { speakHeadword(snapshot: snapshot) },
                            onToggleList: { listID in
                                toggleListMembership(listID: listID, snapshot: snapshot)
                            },
                            onCreateList: {
                                pendingNewListName = ""
                                isPromptingForNewListName = true
                            }
                        )
                    }
                    SectionCard {
                        MeaningSection(senses: snapshot.senses)
                    }
                    if snapshot.entryCards.isEmpty == false {
                        SectionCard {
                            EntryCardsSection(cards: snapshot.entryCards)
                        }
                    }
                    if snapshot.conjugations.isEmpty == false {
                        SectionCard {
                            ConjugationsSection(conjugations: snapshot.conjugations)
                        }
                    }
                    if snapshot.grammarHints.isEmpty == false {
                        SectionCard {
                            GrammarSection(items: snapshot.grammarHints)
                        }
                    }
                    if snapshot.similarWords.isEmpty == false {
                        SectionCard {
                            SimilarWordsSection(words: snapshot.similarWords)
                        }
                    }
                    if snapshot.kanjiRows.isEmpty == false {
                        SectionCard {
                            KanjiSection(rows: snapshot.kanjiRows)
                        }
                    }
                    SectionCard {
                        NotesSection(text: notesBinding(snapshot: snapshot))
                    }
                    if snapshot.clippings.isEmpty == false {
                        SectionCard {
                            ContainedInSection(clippings: snapshot.clippings) { note in
                                router.noteToOpen = note
                                router.selectedTab = .paste
                                dismiss()
                            }
                        }
                    }
                    SectionCard {
                        ExampleSection(examples: snapshot.examples) { tappedSurface in
                            showExampleTokenPreview(for: tappedSurface)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle((snapshot?.headword ?? request.term.surface).trimmingCharacters(in: .whitespacesAndNewlines))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadTaskKey) {
            await load()
        }
        .navigationDestination(item: $exampleNavigationTarget) { target in
            WordDefinitionView(
                request: .init(
                    term: .init(surface: target.surface, kana: nil),
                    context: .init(sentence: nil, lemmaCandidates: [], tokenPartOfSpeech: nil, tokenParts: []),
                    metadata: .init(sourceNoteID: request.metadata.sourceNoteID)
                )
            )
        }
        .sheet(item: $activeExampleTokenPreview) { token in
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(token.surface)
                        .font(.title3.weight(.semibold))
                    if let reading = token.reading, reading.isEmpty == false {
                        Text(reading)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let gloss = token.gloss, gloss.isEmpty == false {
                        Text(gloss)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("No quick gloss available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        activeExampleTokenPreview = nil
                        exampleNavigationTarget = ExampleNavigationTarget(surface: token.surface)
                    } label: {
                        Label("Open entry", systemImage: "arrow.right")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .navigationTitle("Token")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert("Create New List", isPresented: $isPromptingForNewListName) {
            TextField("List name", text: $pendingNewListName)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)

            Button("Cancel", role: .cancel) {
                pendingNewListName = ""
            }

            Button("Create") {
                guard let snapshot else { return }
                createListAndAssign(name: pendingNewListName, snapshot: snapshot)
            }
            .disabled(pendingNewListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Create a list and add this word.")
        }
    }

    private var loadTaskKey: String {
        "\(request.term.surface.trimmingCharacters(in: .whitespacesAndNewlines))|\((request.term.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            snapshot = try await Repository.load(request: request, notesStore: notesStore, store: store)
        } catch {
            snapshot = nil
            errorMessage = String(describing: error)
        }
        isLoading = false
    }

    private func notesBinding(snapshot: Snapshot) -> Binding<String> {
        Binding(
            get: {
                currentWord?.note ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let word = currentWord {
                    store.update(
                        id: word.id,
                        surface: word.surface,
                        dictionarySurface: word.dictionarySurface,
                        kana: word.kana,
                        meaning: word.meaning,
                        note: trimmed.isEmpty ? nil : newValue
                    )
                } else if trimmed.isEmpty == false {
                    let reading = snapshot.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.add(
                        surface: snapshot.headword,
                        dictionarySurface: snapshot.headword,
                        kana: (reading?.isEmpty == false) ? reading : nil,
                        meaning: snapshot.primaryMeaning,
                        note: newValue,
                        sourceNoteID: request.metadata.sourceNoteID
                    )
                }
            }
        )
    }

    private var currentWord: Word? {
        let surface = request.term.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let kana = request.term.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (kana?.isEmpty == false) ? kana : nil
        guard surface.isEmpty == false else { return nil }
        return store.words.first {
            if let dictionarySurface = $0.dictionarySurface,
               dictionarySurface == surface,
               $0.kana == normalizedKana {
                return true
            }
            return $0.surface == surface && $0.kana == normalizedKana
        }
    }

    private func speakHeadword(snapshot: Snapshot) {
        let text = (snapshot.reading ?? snapshot.headword).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return }
        SpeechManager.shared.speak(text: text, language: "ja-JP")
    }

    private func listOptions(for snapshot: Snapshot) -> [ListOption] {
        let selected = Set(wordForMembership(snapshot: snapshot)?.listIDs ?? [])
        return store.lists
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { list in
                ListOption(id: list.id, name: list.name, isSelected: selected.contains(list.id))
            }
    }

    private func wordForMembership(snapshot: Snapshot) -> Word? {
        let headword = snapshot.headword.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = snapshot.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = (reading?.isEmpty == false) ? reading : nil
        return store.words.first {
            let ds = $0.dictionarySurface?.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = $0.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSurface = (ds == headword) || (s == headword)
            guard matchesSurface else { return false }
            return $0.kana == normalizedReading
        }
    }

    private func ensureWordForMembership(snapshot: Snapshot) -> Word? {
        if let existing = wordForMembership(snapshot: snapshot) {
            return existing
        }

        let reading = snapshot.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        store.add(
            surface: snapshot.headword,
            dictionarySurface: snapshot.headword,
            kana: (reading?.isEmpty == false) ? reading : nil,
            meaning: snapshot.primaryMeaning,
            sourceNoteID: request.metadata.sourceNoteID
        )
        return wordForMembership(snapshot: snapshot)
    }

    private func toggleListMembership(listID: UUID, snapshot: Snapshot) {
        guard let word = ensureWordForMembership(snapshot: snapshot) else { return }
        var next = Set(word.listIDs)
        if next.contains(listID) {
            next.remove(listID)
        } else {
            next.insert(listID)
        }
        store.setLists(forWordID: word.id, listIDs: Array(next))
    }

    private func createListAndAssign(name: String, snapshot: Snapshot) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        if let existing = store.lists.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            addWordToList(listID: existing.id, snapshot: snapshot)
            return
        }

        if let created = store.createList(name: trimmed) {
            addWordToList(listID: created.id, snapshot: snapshot)
        }
    }

    private func addWordToList(listID: UUID, snapshot: Snapshot) {
        guard let word = ensureWordForMembership(snapshot: snapshot) else { return }
        var next = Set(word.listIDs)
        next.insert(listID)
        store.setLists(forWordID: word.id, listIDs: Array(next))
    }

    private func showExampleTokenPreview(for rawSurface: String) {
        let surface = rawSurface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.isEmpty == false else { return }

        Task {
            let keys = DictionaryKeyPolicy.keys(forDisplayKey: surface)
            guard keys.lookupKey.isEmpty == false else {
                await MainActor.run {
                    activeExampleTokenPreview = ExampleTokenPreview(surface: surface, reading: nil, gloss: nil)
                }
                return
            }

            let rows = (try? await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 1)) ?? []
            let row = rows.first
            await MainActor.run {
                activeExampleTokenPreview = ExampleTokenPreview(
                    surface: surface,
                    reading: row?.kana,
                    gloss: row?.gloss
                )
            }
        }
    }
}

private extension WordDefinitionView {
    struct Snapshot {
        let headword: String
        let reading: String?
        let lemmaLine: String?
        let formLine: String?
        let partOfSpeech: String?
        let isCommon: Bool
        let pitchAccents: [PitchAccent]
        let senses: [SenseItem]
        let conjugations: [VerbConjugation]
        let grammarHints: [DetectedGrammarPattern]
        let similarWords: [String]
        let entryCards: [EntryCard]
        let kanjiRows: [KanjiItem]
        let clippings: [Note]
        let examples: [ExampleItem]
        let primaryMeaning: String
    }

    struct EntryCard: Identifiable {
        let id: String
        let headword: String
        let reading: String?
        let isCommon: Bool
        let forms: [String]
        let senses: [String]
    }

    struct SenseItem: Identifiable {
        let id: String
        let number: Int
        let gloss: String
        let tags: [String]
    }

    struct KanjiItem: Identifiable {
        let id: String
        let character: String
        let coreMeaning: String
        let onyomi: String?
        let kunyomi: String?
    }

    struct ExampleItem: Identifiable {
        let id: String
        let jpText: String
        let enText: String
        let attributedJP: NSAttributedString
        let semanticSpans: [SemanticSpan]
    }

    enum Repository {
        static func load(request: Request, notesStore: NotesStore, store: WordsStore) async throws -> Snapshot {
            let trimmedSurface = request.term.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedKana = request.term.kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKana = (trimmedKana?.isEmpty == false) ? trimmedKana : nil

            var queryTerms: [String] = []
            if trimmedSurface.isEmpty == false { queryTerms.append(trimmedSurface) }
            if let normalizedKana, queryTerms.contains(normalizedKana) == false {
                queryTerms.append(normalizedKana)
            }

            var mergedEntries: [DictionaryEntry] = []
            var seen = Set<String>()
            for term in queryTerms {
                let key = DictionaryKeyPolicy.keys(forDisplayKey: term).lookupKey
                guard key.isEmpty == false else { continue }
                let rows = try await DictionarySQLiteStore.shared.lookupExact(term: key, limit: 64)
                for row in rows where seen.insert(row.id).inserted {
                    mergedEntries.append(row)
                }
            }

            var resolvedLemma: String?
            var resolvedTrace: [Deinflector.AppliedRule] = []
            if mergedEntries.isEmpty,
               trimmedSurface.isEmpty == false,
               let deinflector = try? Deinflector.loadBundled(named: "deinflect") {
                let candidates = deinflector.deinflect(trimmedSurface, maxDepth: 8, maxResults: 48)
                for candidate in candidates where candidate.trace.isEmpty == false {
                    let key = DictionaryKeyPolicy.keys(forDisplayKey: candidate.baseForm).lookupKey
                    guard key.isEmpty == false else { continue }
                    let rows = try await DictionarySQLiteStore.shared.lookupExact(term: key, limit: 64)
                    guard rows.isEmpty == false else { continue }
                    for row in rows where seen.insert(row.id).inserted {
                        mergedEntries.append(row)
                    }
                    resolvedLemma = candidate.baseForm
                    resolvedTrace = candidate.trace
                    break
                }
            }

            mergedEntries = mergedEntries.filter { $0.isCommon } + mergedEntries.filter { $0.isCommon == false }

            let entryIDs = mergedEntries.map(\.entryID)
            let details = try await DictionarySQLiteStore.shared.fetchEntryDetails(for: entryIDs)
            let orderedDetails = details.filter { $0.isCommon } + details.filter { $0.isCommon == false }

            let headword: String = {
                if let first = orderedDetails.first,
                   let text = first.kanjiForms.first?.text,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return text
                }
                if let first = orderedDetails.first,
                   let text = first.kanaForms.first?.text,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return text
                }
                if let normalizedKana, trimmedSurface.isEmpty {
                    return normalizedKana
                }
                return trimmedSurface
            }()

            let reading: String? = {
                if let normalizedKana { return normalizedKana }
                let fallback = orderedDetails.first?.kanaForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return (fallback?.isEmpty == false) ? fallback : nil
            }()

            let senses = buildSenses(from: orderedDetails)
            let entryCards = buildEntryCards(from: orderedDetails, fallbackHeadword: headword)
            let partOfSpeech = buildPartOfSpeech(from: orderedDetails)
            let isCommon = orderedDetails.first?.isCommon ?? mergedEntries.first?.isCommon ?? false
            let conjugations = buildConjugations(from: orderedDetails, headword: headword)
            let grammarHints = (request.context.sentence?.isEmpty == false) ? GrammarPatternDetector.detect(in: request.context.sentence ?? "") : []
            let similarWords = JapaneseSimilarityService.neighbors(for: headword, maxCount: 10).filter { $0 != headword }
            let pitchAccents = try await loadPitchAccents(from: orderedDetails)
            let kanjiRows = try await loadKanjiRows(headword: headword)
            let clippings = buildClippings(headword: headword, reading: reading, notesStore: notesStore, store: store, sourceNoteID: request.metadata.sourceNoteID)
            let examples = try await loadExamples(headword: headword, reading: reading)
            let primaryMeaning = senses.first?.gloss ?? mergedEntries.first.map { firstGloss($0.gloss) } ?? ""
            let lemmaLine: String? = {
                guard let lemma = resolvedLemma?.trimmingCharacters(in: .whitespacesAndNewlines), lemma.isEmpty == false else { return nil }
                guard lemma != headword else { return nil }
                return "Lemma: \(lemma)"
            }()
            let formLine: String? = {
                guard resolvedTrace.isEmpty == false else { return nil }
                let labels = resolvedTrace.map { mapDeinflectionReason($0.reason) }
                guard labels.isEmpty == false else { return nil }
                return "Form: \(labels.joined(separator: " → "))"
            }()

            return Snapshot(
                headword: headword,
                reading: reading,
                lemmaLine: lemmaLine,
                formLine: formLine,
                partOfSpeech: partOfSpeech,
                isCommon: isCommon,
                pitchAccents: pitchAccents,
                senses: senses,
                conjugations: conjugations,
                grammarHints: grammarHints,
                similarWords: similarWords,
                entryCards: entryCards,
                kanjiRows: kanjiRows,
                clippings: clippings,
                examples: examples,
                primaryMeaning: primaryMeaning
            )
        }

        private static func buildConjugations(from details: [DictionaryEntryDetail], headword: String) -> [VerbConjugation] {
            let tags = details
                .flatMap { $0.senses }
                .flatMap { $0.partsOfSpeech }

            guard let verbClass = VerbConjugator.detectVerbClass(fromJMDictPosTags: tags) else { return [] }

            let base: String = {
                if let reading = details.first?.kanaForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                   reading.isEmpty == false {
                    return reading
                }
                return headword
            }()

            return VerbConjugator.conjugations(for: base, verbClass: verbClass, set: .all)
        }

        private static func buildEntryCards(from details: [DictionaryEntryDetail], fallbackHeadword: String) -> [EntryCard] {
            var cards: [EntryCard] = []
            cards.reserveCapacity(details.count)

            for detail in details {
                let headwordRaw = detail.kanjiForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let readingRaw = detail.kanaForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let headword = (headwordRaw?.isEmpty == false) ? headwordRaw! : fallbackHeadword
                let reading = (readingRaw?.isEmpty == false) ? readingRaw : nil

                var formSet = Set<String>()
                var forms: [String] = []
                for form in (detail.kanjiForms + detail.kanaForms) {
                    let text = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard text.isEmpty == false else { continue }
                    if formSet.insert(text).inserted {
                        forms.append(text)
                    }
                }

                var senses: [String] = []
                for sense in detail.senses.sorted(by: { $0.orderIndex < $1.orderIndex }) {
                    let gloss = sense.glosses
                        .sorted(by: { $0.orderIndex < $1.orderIndex })
                        .map(\.text)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.isEmpty == false }
                        .joined(separator: "; ")
                    if gloss.isEmpty == false {
                        senses.append(gloss)
                    }
                }

                cards.append(EntryCard(
                    id: "entry-card-\(detail.entryID)",
                    headword: headword,
                    reading: reading,
                    isCommon: detail.isCommon,
                    forms: forms,
                    senses: senses
                ))
            }

            return cards
        }

        private static func mapDeinflectionReason(_ raw: String) -> String {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "-te": return "て-form"
            case "-ta", "past": return "past"
            case "negative": return "negative"
            case "polite": return "polite"
            case "potential": return "potential"
            case "passive": return "passive"
            case "causative": return "causative"
            case "volitional": return "volitional"
            case "imperative": return "imperative"
            case "conditional": return "conditional"
            default: return raw
            }
        }

        private static func buildSenses(from details: [DictionaryEntryDetail]) -> [SenseItem] {
            var output: [SenseItem] = []
            var number = 1
            for detail in details {
                let orderedSenses = detail.senses.sorted { $0.orderIndex < $1.orderIndex }
                for sense in orderedSenses {
                    let gloss = sense.glosses
                        .sorted { $0.orderIndex < $1.orderIndex }
                        .map(\.text)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.isEmpty == false }
                        .joined(separator: "; ")
                    guard gloss.isEmpty == false else { continue }

                    let tags = (sense.miscellaneous + sense.fields + sense.dialects)
                        .map { expandSenseTag($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .filter { $0.isEmpty == false }

                    output.append(SenseItem(id: "sense-\(sense.id)", number: number, gloss: gloss, tags: tags))
                    number += 1
                }
            }
            return output
        }

        private static func buildPartOfSpeech(from details: [DictionaryEntryDetail]) -> String? {
            var labels: [String] = []
            for detail in details {
                for sense in detail.senses {
                    for tag in sense.partsOfSpeech {
                        let mapped = mapPartOfSpeech(tag)
                        guard labels.contains(mapped) == false else { continue }
                        labels.append(mapped)
                    }
                }
            }
            return labels.first
        }

        private static func loadPitchAccents(from details: [DictionaryEntryDetail]) async throws -> [PitchAccent] {
            guard await DictionarySQLiteStore.shared.supportsPitchAccents() else { return [] }
            var out: [PitchAccent] = []
            var seen = Set<String>()

            for detail in details {
                guard let reading = detail.kanaForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      reading.isEmpty == false else { continue }

                let surface = (detail.kanjiForms.first?.text ?? reading).trimmingCharacters(in: .whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }

                let rows = try await DictionarySQLiteStore.shared.fetchPitchAccents(surface: surface, reading: reading)
                for row in rows {
                    let key = "\(row.surface)|\(row.reading)|\(row.accent)|\(row.morae)|\(row.kind ?? "")"
                    if seen.insert(key).inserted {
                        out.append(row)
                    }
                }
            }

            return out.sorted {
                if $0.accent != $1.accent { return $0.accent < $1.accent }
                return $0.morae < $1.morae
            }
        }

        private static func loadKanjiRows(headword: String) async throws -> [KanjiItem] {
            let chars = Array(headword).map(String.init).filter { containsKanji($0) }
            guard chars.isEmpty == false else { return [] }

            var rows: [KanjiItem] = []
            for char in chars {
                let key = DictionaryKeyPolicy.keys(forDisplayKey: char).lookupKey
                guard key.isEmpty == false else { continue }

                let matches = try await DictionarySQLiteStore.shared.lookupExact(term: key, limit: 8)
                guard let first = matches.first else {
                    rows.append(KanjiItem(id: char, character: char, coreMeaning: "", onyomi: nil, kunyomi: nil))
                    continue
                }

                let details = try await DictionarySQLiteStore.shared.fetchEntryDetails(for: [first.entryID])
                let detail = details.first
                let readingSummary = detail?.kanaForms
                    .prefix(3)
                    .map { $0.text }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                let onyomi = readingSummary?
                    .filter { isKatakana($0) }
                    .joined(separator: " ・ ")
                let kunyomi = readingSummary?
                    .filter { isHiragana($0) }
                    .joined(separator: " ・ ")
                let meaning = detail?.senses.first?.glosses.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                rows.append(
                    KanjiItem(
                        id: char,
                        character: char,
                        coreMeaning: meaning,
                        onyomi: (onyomi?.isEmpty == false) ? onyomi : nil,
                        kunyomi: (kunyomi?.isEmpty == false) ? kunyomi : nil
                    )
                )
            }
            return rows
        }

        private static func buildClippings(headword: String, reading: String?, notesStore: NotesStore, store: WordsStore, sourceNoteID: UUID?) -> [Note] {
            let matching = store.words.filter {
                let wordSurface = ($0.dictionarySurface ?? $0.surface).trimmingCharacters(in: .whitespacesAndNewlines)
                guard wordSurface == headword else { return false }
                if let reading {
                    return ($0.kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == reading
                }
                return true
            }

            var noteIDs = Set(matching.flatMap(\.sourceNoteIDs))
            if let sourceNoteID { noteIDs.insert(sourceNoteID) }
            if noteIDs.isEmpty { return [] }

            return notesStore.notes
                .filter { noteIDs.contains($0.id) }
                .sorted { $0.createdAt > $1.createdAt }
        }

        private static func loadExamples(headword: String, reading: String?) async throws -> [ExampleItem] {
            var terms: [String] = [headword]
            if let reading, terms.contains(reading) == false {
                terms.append(reading)
            }

            let examples = try await DictionarySQLiteStore.shared.fetchExampleSentences(containing: terms, limit: 8)
            var output: [ExampleItem] = []
            output.reserveCapacity(examples.count)

            for sentence in examples {
                let rendered = await FuriganaPipelineService().render(
                    .init(
                        text: sentence.jpText,
                        showFurigana: true,
                        needsTokenHighlights: false,
                        textSize: 20,
                        furiganaSize: 11,
                        recomputeSpans: true,
                        existingSpans: nil,
                        existingSemanticSpans: [],
                        amendedSpans: nil,
                        hardCuts: [],
                        readingOverrides: [],
                        context: "dictionary-example",
                        padHeadwordSpacing: false,
                        headwordSpacingAmount: 1,
                        knownWordSurfaceKeys: []
                    )
                )

                output.append(
                    ExampleItem(
                        id: sentence.id,
                        jpText: sentence.jpText,
                        enText: sentence.enText,
                        attributedJP: rendered.attributedString ?? NSAttributedString(string: sentence.jpText),
                        semanticSpans: rendered.semanticSpans
                    )
                )
            }
            return output
        }

        private static func mapPartOfSpeech(_ raw: String) -> String {
            let tag = raw.lowercased()
            if tag.hasPrefix("v") { return "Verb" }
            if tag.hasPrefix("adj") { return "Adjective" }
            if tag.hasPrefix("adv") { return "Adverb" }
            if tag.hasPrefix("n") || tag == "pn" { return "Noun" }
            if tag.hasPrefix("prt") { return "Particle" }
            if tag.hasPrefix("aux") { return "Auxiliary" }
            return raw
        }

        private static func expandSenseTag(_ tag: String) -> String {
            switch tag.lowercased() {
            case "uk": return "usu. kana"
            case "sl": return "slang"
            case "col": return "colloquial"
            case "arch": return "archaic"
            case "obs": return "obsolete"
            case "vulg": return "vulgar"
            default: return tag
            }
        }

        private static func containsKanji(_ text: String) -> Bool {
            text.unicodeScalars.contains {
                (0x3400...0x4DBF).contains($0.value) ||
                (0x4E00...0x9FFF).contains($0.value) ||
                (0xF900...0xFAFF).contains($0.value)
            }
        }

        private static func isHiragana(_ text: String) -> Bool {
            guard text.isEmpty == false else { return false }
            return text.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
        }

        private static func isKatakana(_ text: String) -> Bool {
            guard text.isEmpty == false else { return false }
            return text.unicodeScalars.allSatisfy {
                (0x30A0...0x30FF).contains($0.value) || (0xFF66...0xFF9F).contains($0.value)
            }
        }

        private static func firstGloss(_ raw: String) -> String {
            raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        }
    }
}

private struct HeaderSection: View {
    let snapshot: WordDefinitionView.Snapshot
    let listOptions: [WordDefinitionView.ListOption]
    let onSpeak: () -> Void
    let onToggleList: (UUID) -> Void
    let onCreateList: () -> Void

    private var isInAnyList: Bool {
        listOptions.contains(where: { $0.isSelected })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Text(snapshot.headword)
                    .font(.system(size: 34, weight: .bold, design: .default))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button(action: onSpeak) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(Color(uiColor: .tertiarySystemBackground), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button {
                            onCreateList()
                        } label: {
                            Label("Create new list", systemImage: "plus")
                        }

                        Divider()

                        if listOptions.isEmpty {
                            Text("No lists")
                        } else {
                            Section("Add to list") {
                                ForEach(listOptions) { option in
                                    Button {
                                        onToggleList(option.id)
                                    } label: {
                                        Label(option.name, systemImage: option.isSelected ? "checkmark" : "")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: isInAnyList ? "checkmark.circle.fill" : "plus.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .background(Color(uiColor: .tertiarySystemBackground), in: Circle())
                            .foregroundStyle(isInAnyList ? Color.accentColor : .secondary)
                    }
                }
            }

            if snapshot.pitchAccents.isEmpty == false,
               let reading = snapshot.reading {
                PitchAccentSection(
                    headword: snapshot.headword,
                    reading: reading,
                    accents: snapshot.pitchAccents,
                    showsTitle: false,
                    visualScale: 1.9
                )
            }

            if let lemmaLine = snapshot.lemmaLine, lemmaLine.isEmpty == false {
                Text(lemmaLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let formLine = snapshot.formLine, formLine.isEmpty == false {
                Text(formLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .center, spacing: 8) {
                if let partOfSpeech = snapshot.partOfSpeech {
                    Text(partOfSpeech)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if snapshot.isCommon {
                    Text("COMMON")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }

        }
    }
}

private struct EntryCardsSection: View {
    let cards: [WordDefinitionView.EntryCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Entries")
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                AlternatingRow(index: index) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(card.headword)
                                .font(.subheadline.weight(.semibold))
                            if let reading = card.reading,
                               reading.isEmpty == false,
                               reading != card.headword {
                                Text(reading)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if card.isCommon {
                                Text("COMMON")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        /*
                        if card.forms.isEmpty == false {
                            Text("Forms: \(card.forms.joined(separator: " ・ "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        */
                        ForEach(Array(card.senses.prefix(3).enumerated()), id: \.offset) { _, gloss in
                            Text(gloss)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

private struct MeaningSection: View {
    let senses: [WordDefinitionView.SenseItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(senses.enumerated()), id: \.element.id) { index, sense in
                AlternatingRow(index: index) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sense.gloss)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)

                        if sense.tags.isEmpty == false {
                            InlineWrapLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(Array(sense.tags.enumerated()), id: \.offset) { _, tag in
                                    Text(tag)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct KanjiSection: View {
    let rows: [WordDefinitionView.KanjiItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Kanji")
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.character)
                        .font(.title2.weight(.semibold))
                        .frame(width: 32, alignment: .leading)

                    VStack(alignment: .leading, spacing: 2) {
                        if row.coreMeaning.isEmpty == false {
                            Text(row.coreMeaning)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let onyomi = row.onyomi,
                           onyomi.isEmpty == false {
                            Text("Onyomi: \(onyomi)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let kunyomi = row.kunyomi,
                           kunyomi.isEmpty == false {
                            Text("Kunyomi: \(kunyomi)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct ConjugationsSection: View {
    let conjugations: [VerbConjugation]
    @State private var showAllConjugations: Bool = false

    private var commonVisible: [VerbConjugation] {
        let commonLabels: [String] = [
            "Polite (ます)",
            "Negative (ない)",
            "Past (た)",
            "て-form",
            "Potential",
            "Volitional"
        ]
        var byLabel: [String: VerbConjugation] = [:]
        for item in conjugations where byLabel[item.label] == nil {
            byLabel[item.label] = item
        }
        return commonLabels.compactMap { byLabel[$0] }
    }

    private var visibleConjugations: [VerbConjugation] {
        if showAllConjugations { return conjugations }
        let common = commonVisible
        return common.isEmpty ? conjugations : common
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Conjugations")
            ForEach(Array(visibleConjugations.enumerated()), id: \.offset) { index, item in
                AlternatingRow(index: index) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                        Text(item.surface)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if conjugations.count > visibleConjugations.count {
                Button {
                    showAllConjugations = true
                } label: {
                    Text("Show all conjugations")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
            } else if showAllConjugations && conjugations.count > commonVisible.count {
                Button {
                    showAllConjugations = false
                } label: {
                    Text("Show fewer")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct GrammarSection: View {
    let items: [DetectedGrammarPattern]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Grammar")
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AlternatingRow(index: index) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                        Text(item.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SimilarWordsSection: View {
    let words: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Similar Words")
            InlineWrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(words, id: \.self) { word in
                    Text(word)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: .tertiarySystemBackground), in: Capsule())
                }
            }
        }
    }
}

private struct NotesSection: View {
    @Binding var text: String
    @State private var isExpanded: Bool = false
    @State private var hasInitialized: Bool = false

    private var hasContent: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionTitle(text: "Notes")
                Spacer(minLength: 0)
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "minus" : "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                TextEditor(text: $text)
                    .frame(minHeight: 96)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            }
        }
        .onAppear {
            guard hasInitialized == false else { return }
            isExpanded = hasContent
            hasInitialized = true
        }
    }
}

private struct ContainedInSection: View {
    let clippings: [Note]
    let onTap: (Note) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Contained In")
            ForEach(clippings) { clipping in
                Button {
                    onTap(clipping)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(clipping.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? clipping.title! : "Untitled")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(clipping.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ExampleSection: View {
    let examples: [WordDefinitionView.ExampleItem]
    let onWordTap: (String) -> Void
    @State private var showAllExamples: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Example Sentences")

            if examples.isEmpty {
                Text("No example sentences found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let visibleExamples = showAllExamples ? examples : Array(examples.prefix(3))
                ForEach(Array(visibleExamples.enumerated()), id: \.element.id) { index, example in
                    AlternatingRow(index: index) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .top, spacing: 8) {
                                RubyText(
                                    attributed: example.attributedJP,
                                    fontSize: 20,
                                    lineHeightMultiple: 1.0,
                                    extraGap: 4,
                                    isScrollEnabled: false,
                                    allowSystemTextSelection: false,
                                    wrapLines: true,
                                    horizontalScrollEnabled: false,
                                    semanticSpans: example.semanticSpans,
                                    onSpanSelection: { selection in
                                        guard let selection else { return }
                                        onWordTap(selection.semanticSpan.surface)
                                    }
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    SpeechManager.shared.speak(text: example.jpText, language: "ja-JP")
                                } label: {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(width: 28, height: 28)
                                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Play sentence audio")
                                .padding(.top, 1)
                            }

                            Text(example.enText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if examples.count > 3 {
                    Button {
                        showAllExamples.toggle()
                    } label: {
                        Text(showAllExamples ? "Show less" : "Show more")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct AlternatingRow<Content: View>: View {
    let index: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(index.isMultiple(of: 2) ? Color(uiColor: .tertiarySystemBackground) : Color(uiColor: .secondarySystemBackground))
            )
    }
}

private struct SectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
        )
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
