import SwiftUI
import NaturalLanguage

struct WordDefinitionsView: View {
    @EnvironmentObject var store: WordsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var notesStore: NotesStore
    @Environment(\.dismiss) private var dismiss

    let surface: String
    let kana: String?
    let contextSentence: String?
    let lemmaCandidates: [String]
    let tokenPartOfSpeech: String?
    let sourceNoteID: UUID?
    let tokenParts: [TokenPart]

    struct TokenPart: Identifiable, Hashable {
        let id: String
        let surface: String
        let kana: String?

        init(id: String, surface: String, kana: String?) {
            self.id = id
            self.surface = surface
            self.kana = kana
        }
    }

    @State var entries: [DictionaryEntry] = []
    @State var entryDetails: [DictionaryEntryDetail] = []
    @State var isLoading: Bool = false
    @State var errorMessage: String? = nil
    @State var debugSQL: String = ""
    @State var expandedDefinitionRowIDs: Set<String> = []

    // Used to prevent stale async work (from a previous headword) from overwriting
    // the currently displayed definitions when this view is reused inside a sheet.
    @State var activeLoadRequestID: UUID = UUID()

    @State var exampleSentences: [ExampleSentence] = []
    @State var isLoadingExampleSentences: Bool = false
    @State var showAllExampleSentences: Bool = false

    @State var hasPitchAccentsTable: Bool? = nil
    @State var pitchAccentsForTerm: [PitchAccent] = []
    @State var isLoadingPitchAccents: Bool = false

    @State var detectedGrammar: [DetectedGrammarPattern] = []
    @State var similarWords: [String] = []

    @State var headerLemmaLine: String? = nil
    @State var headerFormLine: String? = nil

    // Resolved lemma information (computed when we have to deinflect during lookup).
    @State var resolvedLemmaForLookup: String? = nil
    @State var resolvedDeinflectionTrace: [Deinflector.AppliedRule] = []

    @State var showAllConjugations: Bool = false

    @State var componentPreviewPart: TokenPart? = nil

    @State var inferredTokenParts: [TokenPart] = []

    struct NavigationTarget: Identifiable, Hashable {
        let id = UUID()
        let surface: String
        let kana: String?
        let contextSentence: String?
    }

    @State var navigationTarget: NavigationTarget? = nil

    struct ActiveToken: Identifiable, Hashable {
        let id: String
        let text: String
        let mode: DictionarySearchMode
        let contextSentence: String?
    }

    @State var activeToken: ActiveToken? = nil
    @State var activeTokenLookupResult: DictionaryEntry? = nil
    @State var isLoadingActiveTokenLookup: Bool = false

    struct ListAssignmentTarget: Identifiable, Hashable {
        let id = UUID()
        let surface: String
        let kana: String?
        let meaning: String
    }

    @State var listAssignmentTarget: ListAssignmentTarget? = nil

    struct DefinitionRow: Identifiable, Hashable {
        let headword: String
        let reading: String?
        let pages: [DefinitionPage]

        var id: String { "\(headword)#\(reading ?? "(no-reading)")" }
    }

    struct DefinitionPage: Identifiable, Hashable {
        let gloss: String
        /// Representative entry for bookmarking.
        let entry: DictionaryEntry

        var id: String { "\(entry.id)#\(gloss)" }
    }

    var body: some View {
        List {
            // Header (note → title)
            Section {
                if let noteID = sourceNoteID, let note = notesStore.notes.first(where: { $0.id == noteID }) {
                    HStack(spacing: 10) {
                        Image(systemName: "book")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((note.title?.isEmpty == false ? note.title : nil) ?? "Untitled")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            router.noteToOpen = note
                            router.selectedTab = .paste
                            // This view is presented inside a sheet; switching tabs alone does not
                            // reveal the paste view while the sheet is still covering the UI.
                            dismiss()
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                    // .modifier(dbgBG(LayoutDebugColor.DBG_TEAL__HeaderNoteRow))
                    // .modifier(dbgRowBG(LayoutDebugColor.DBG_TEAL__HeaderNoteRow))
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(titleText)
                        .font(.title2.weight(.semibold))
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // .modifier(dbgBG(LayoutDebugColor.DBG_MINT__HeaderTitleRow))
                        // .modifier(dbgRowBG(LayoutDebugColor.DBG_MINT__HeaderTitleRow))

                    Button {
                        let trimmedKana = kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
                        let speechText = trimmedKana.isEmpty == false ? trimmedKana : trimmedSurface
                        SpeechManager.shared.speak(text: speechText, language: "ja-JP")
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Speak")
                    .disabled(surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let headerLemmaLine {
                    Text(headerLemmaLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let headerFormLine {
                    Text(headerFormLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let posLine = partOfSpeechSummaryLine() {
                    Text(posLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // .modifier(dbgRowBG(LayoutDebugColor.DBG_CYAN__SectionHeader))

            if let saved = activeSavedWord {
                Section("Lists") {
                    let assigned = assignedLists(for: saved)

                    if assigned.isEmpty {
                        Text("Not in any lists")
                            .foregroundStyle(.secondary)
                    } else {
                        InlineWrapLayout(spacing: 8, lineSpacing: 8) {
                            ForEach(assigned) { list in
                                Text(list.name)
                                    .font(.caption.weight(.semibold))
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }

            if let morph = verbMorphologyAnalysis {
                Section("Verb") {
                    Text(verbClassDisplayName(morph.verbClass))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Form")
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text(morph.formDisplay)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Function")
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text(morph.functionDisplay)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(morph.pitchNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }

            // Pitch accents render under each resolved dictionary entry (keyed by kana reading).
            // Keep a single status section for missing/loading/empty states, and fall back to the
            // old global display only when no entries are available.
            if entryDetails.isEmpty {
                Section("Pitch Accent") {
                    pitchAccentGlobalContent
                }
            } else if hasPitchAccentsTable == false || isLoadingPitchAccents || pitchAccentsForTerm.isEmpty {
                Section("Pitch Accent") {
                    pitchAccentStatusOnlyContent
                }
            }

            if shouldShowVerbConjugations {
                Section("Conjugations") {
                    if let verbConjugationHeaderLine {
                        Text(verbConjugationHeaderLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let visible = verbConjugations(set: .common)
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)

                            Text(item.surface)
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .textSelection(.enabled)
                    }

                    if showAllConjugations {
                        Divider()
                            .padding(.vertical, 4)

                        let commonLabelSet = Set(visible.map(\.label))
                        let all = verbConjugations(set: .all).filter { commonLabelSet.contains($0.label) == false }
                        ForEach(Array(all.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(item.label)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 140, alignment: .leading)

                                Text(item.surface)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .textSelection(.enabled)
                        }
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showAllConjugations.toggle()
                        }
                    } label: {
                        Text(showAllConjugations ? "Show fewer" : "Show all conjugations")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Definitions list
            Section {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                //    .modifier(dbgBG(LayoutDebugColor.DBG_YELLOW__LoadingRow))
                //    .modifier(dbgRowBG(LayoutDebugColor.DBG_YELLOW__LoadingRow))
                } else if let errorMessage, errorMessage.isEmpty == false {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                    //    .modifier(dbgBG(LayoutDebugColor.DBG_RED__ErrorRow))
                    //    .modifier(dbgRowBG(LayoutDebugColor.DBG_RED__ErrorRow))
                } else if entries.isEmpty {
                    Text("No definitions found.")
                        .foregroundStyle(.secondary)
                    //    .modifier(dbgBG(LayoutDebugColor.DBG_ORANGE__EmptyRow))
                    //    .modifier(dbgRowBG(LayoutDebugColor.DBG_ORANGE__EmptyRow))
                } else {
                    ForEach(definitionRows) { row in
                        definitionRowView(row)
                    }
                }
            }

            if detectedGrammar.isEmpty == false {
                Section("Grammar (in context)") {
                    ForEach(detectedGrammar) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.body.weight(.semibold))
                            Text(item.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            if item.matchText.isEmpty == false {
                                Text("Matched: \(item.matchText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if similarWords.isEmpty == false {
                Section("Similar words") {
                    Text(similarWords.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            // .modifier(dbgRowBG(LayoutDebugColor.DBG_CYAN__SectionHeader))

            // Full entries
            if entryDetails.isEmpty == false {
                Section() {
                    ForEach(entryDetails) { detail in
                        entryDetailView(detail)
                    }
                }
                // .modifier(dbgRowBG(LayoutDebugColor.DBG_CYAN__SectionHeader))
            }

            Section("Example sentences") {
                if isLoadingExampleSentences {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                } else if exampleSentences.isEmpty {
                    Text("No example sentences found.")
                        .foregroundStyle(.secondary)
                } else {
                    let maxVisible = 3
                    let visible = showAllExampleSentences ? exampleSentences : Array(exampleSentences.prefix(maxVisible))

                    ForEach(visible) { sentence in
                        exampleSentenceRow(sentence)
                    }

                    if exampleSentences.count > maxVisible {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showAllExampleSentences.toggle()
                            }
                        } label: {
                            Text(showAllExampleSentences ? "Show fewer" : "Show more")
                                .font(.callout.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // .modifier(dbgBG(LayoutDebugColor.DBG_GRAY__List))
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadTaskKey) {
            ViewedDictionaryHistoryStore.shared.record(surface: titleText, kana: kana)
            showAllConjugations = false
            await updateHeaderLemmaAndFormLines()
            await load()

            let historyID = "\(titleText.trimmingCharacters(in: .whitespacesAndNewlines))|\(((kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))"
            let primaryMeaning = definitionRows.first?.pages.first?.gloss
            ViewedDictionaryHistoryStore.shared.updateMeaning(id: historyID, meaning: primaryMeaning)

            refreshContextInsights()
        }
        .sheet(item: $listAssignmentTarget) { target in
            NavigationStack {
                if let wordID = ensureSavedWordID(surface: target.surface, kana: target.kana, meaning: target.meaning) {
                    WordListsAssignmentSheet(wordID: wordID, title: target.surface)
                } else {
                    Text("Save this word first to assign lists.")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
        .sheet(item: $componentPreviewPart) { part in
            ComponentPreviewSheet(part: part) { selectedPart in
                componentPreviewPart = nil
                DispatchQueue.main.async {
                    navigationTarget = NavigationTarget(surface: selectedPart.surface, kana: selectedPart.kana, contextSentence: contextSentence)
                }
            }
        }
        .navigationDestination(item: $navigationTarget) { target in
            WordDefinitionsView(
                surface: target.surface,
                kana: target.kana,
                contextSentence: target.contextSentence,
                lemmaCandidates: [],
                tokenPartOfSpeech: nil,
                sourceNoteID: sourceNoteID,
                tokenParts: []
            )
        }
    }
}
