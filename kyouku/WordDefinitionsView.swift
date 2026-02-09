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

    @State private var entries: [DictionaryEntry] = []
    @State private var entryDetails: [DictionaryEntryDetail] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var debugSQL: String = ""
    @State private var expandedDefinitionRowIDs: Set<String> = []

    // Used to prevent stale async work (from a previous headword) from overwriting
    // the currently displayed definitions when this view is reused inside a sheet.
    @State private var activeLoadRequestID: UUID = UUID()

    @State private var exampleSentences: [ExampleSentence] = []
    @State private var isLoadingExampleSentences: Bool = false
    @State private var showAllExampleSentences: Bool = false

    @State private var hasPitchAccentsTable: Bool? = nil
    @State private var pitchAccentsForTerm: [PitchAccent] = []
    @State private var isLoadingPitchAccents: Bool = false

    @State private var detectedGrammar: [DetectedGrammarPattern] = []
    @State private var similarWords: [String] = []

    @State private var headerLemmaLine: String? = nil
    @State private var headerFormLine: String? = nil

    // Resolved lemma information (computed when we have to deinflect during lookup).
    @State private var resolvedLemmaForLookup: String? = nil
    @State private var resolvedDeinflectionTrace: [Deinflector.AppliedRule] = []

    @State private var showAllConjugations: Bool = false

    @State private var componentPreviewPart: TokenPart? = nil

    @State private var inferredTokenParts: [TokenPart] = []

    private struct NavigationTarget: Identifiable, Hashable {
        let id = UUID()
        let surface: String
        let kana: String?
        let contextSentence: String?
    }

    @State private var navigationTarget: NavigationTarget? = nil

    private struct ActiveToken: Identifiable, Hashable {
        let id: String
        let text: String
        let mode: DictionarySearchMode
        let contextSentence: String?
    }

    @State private var activeToken: ActiveToken? = nil
    @State private var activeTokenLookupResult: DictionaryEntry? = nil
    @State private var isLoadingActiveTokenLookup: Bool = false

    private struct ListAssignmentTarget: Identifiable, Hashable {
        let id = UUID()
        let surface: String
        let kana: String?
        let meaning: String
    }

    @State private var listAssignmentTarget: ListAssignmentTarget? = nil

    private struct DefinitionRow: Identifiable, Hashable {
        let headword: String
        let reading: String?
        let pages: [DefinitionPage]

        var id: String { "\(headword)#\(reading ?? "(no-reading)")" }
    }

    private struct DefinitionPage: Identifiable, Hashable {
        let gloss: String
        /// Representative entry for bookmarking.
        let entry: DictionaryEntry

        var id: String { "\(entry.id)#\(gloss)" }
    }

    // Toggle to visualize the view hierarchy / layout responsibilities.
    private let layoutDebugColorsEnabled: Bool = true

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

            let partsForDisplay = displayTokenParts
            if partsForDisplay.count > 1 {
                Section("Components") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("From")
                            .foregroundStyle(.secondary)

                        ForEach(Array(partsForDisplay.enumerated()), id: \.offset) { idx, part in
                            if idx > 0 {
                                Text("+")
                                    .foregroundStyle(.secondary)
                            }

                            Button {
                                componentPreviewPart = part
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(part.surface)
                                        .font(.body.weight(.semibold))
                                    if let kana = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines), kana.isEmpty == false, kana != part.surface {
                                        Text("\(kana)")
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer(minLength: 0)
                    }
                    .textSelection(.enabled)
                }
            }

            if let morph = verbMorphologyAnalysis {
                Section("Morphology") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(morph.surface)
                            .font(.body.weight(.semibold))
                            .textSelection(.enabled)

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Lemma")
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(morph.lemmaDisplay)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .textSelection(.enabled)

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("Verb class")
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(verbClassDisplayName(morph.verbClass))
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

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
            }

            Section("Pitch Accent") {
                if hasPitchAccentsTable == false {
                    Text("Pitch accent data isn’t available in the bundled dictionary (missing pitch_accents table).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isLoadingPitchAccents {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading pitch accents…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                } else if pitchAccentsForTerm.isEmpty {
                    Text("No pitch accents found for this term.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    let morph = verbMorphologyAnalysis
                    let lemmaHeadword = (entryDetails.first.map { primaryHeadword(for: $0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let lemmaReading = (entryDetails.first?.kanaForms.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                    if let morph, lemmaHeadword.isEmpty == false {
                        Text("Shown for lemma: \(morph.lemmaDisplay). Surface-form pitch may differ; it isn’t computed here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let headwordForDisplay = (morph == nil ? titleText : (lemmaHeadword.isEmpty ? titleText : lemmaHeadword))
                    let readingForDisplay = (morph == nil
                        ? (kana ?? entryDetails.first?.kanaForms.first?.text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        : (lemmaReading.isEmpty ? ((kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) : lemmaReading)
                    )
                    PitchAccentSection(
                        headword: headwordForDisplay,
                        reading: readingForDisplay,
                        accents: pitchAccentsForTerm,
                        showsTitle: false,
                        visualScale: 3
                    )
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

            // // SQL debug
            // if debugSQL.isEmpty == false {
            //     Section("SQL Debug") {
            //         ScrollView(.vertical) {
            //             Text(formattedDebugSQL)
            //                 .font(.system(size: 11, design: .monospaced))
            //                 .frame(maxWidth: .infinity, alignment: .leading)
            //                 .textSelection(.enabled)
            //                 .padding(.vertical, 4)
            //         }
            //         .frame(minHeight: 80, maxHeight: 260)
            //         .modifier(dbgBG(LayoutDebugColor.DBG_RED__SQLRow))
            //     }
            //     .modifier(dbgRowBG(LayoutDebugColor.DBG_RED__SQLRow))
            // }
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
                    WordListAssignmentSheet(wordID: wordID, title: target.surface)
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

    private var loadTaskKey: String {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = (kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lemmas = lemmaCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: "|")
        return "\(primary)|\(secondary)|\(lemmas)"
    }

    // MARK: Header
    private var titleText: String {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if primary.isEmpty == false { return primary }
        return kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var primaryLemmaText: String? {
        lemmaCandidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.isEmpty == false })
    }

    private var resolvedLemmaText: String? {
        let a = (resolvedLemmaForLookup ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty == false { return a }
        return primaryLemmaText
    }

    private var resolvedSurfaceText: String {
        titleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isVerbLemma: Bool {
        // Verbs only: gate morphology + lemma-pitch behaviors.
        verbConjugationVerbClass != nil
    }

    private struct VerbMorphologyAnalysis: Hashable {
        let surface: String
        let lemmaSurface: String
        let lemmaDisplay: String
        let verbClass: JapaneseVerbConjugator.VerbClass
        let formDisplay: String
        let functionDisplay: String
        let pitchNote: String
        let isUncertain: Bool
    }

    private var verbMorphologyAnalysis: VerbMorphologyAnalysis? {
        guard isVerbLemma else { return nil }

        let surface = resolvedSurfaceText
        guard surface.isEmpty == false else { return nil }

        let lemmaSurface = (resolvedLemmaText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard lemmaSurface.isEmpty == false else { return nil }

        // Only show for inflected forms.
        guard lemmaSurface != surface else { return nil }

        guard let verbClass = verbConjugationVerbClass else { return nil }

        // Prefer the primary lemma's (kanji,kana) display from the fetched entry details.
        let lemmaHeadword: String = {
            guard let first = entryDetails.first else { return lemmaSurface }
            let h = primaryHeadword(for: first).trimmingCharacters(in: .whitespacesAndNewlines)
            return h.isEmpty ? lemmaSurface : h
        }()
        let lemmaReading: String = (entryDetails.first?.kanaForms.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let lemmaDisplay: String = {
            let h = lemmaHeadword
            let r = lemmaReading
            if h.isEmpty { return lemmaSurface }
            if r.isEmpty { return h }
            if containsKanji(h) {
                return "\(h)（\(r)）"
            }
            // Kana-only lemma.
            return h
        }()

        let allConjs = JapaneseVerbConjugator.conjugations(for: lemmaSurface, verbClass: verbClass, set: .all)
        let matchingLabels: [String] = {
            var seen = Set<String>()
            var out: [String] = []
            for label in allConjs.filter({ $0.surface == surface }).map({ $0.label }) {
                let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.isEmpty == false else { continue }
                if seen.insert(t).inserted { out.append(t) }
            }
            return out
        }()

        let (formDisplay, functionDisplay, uncertain): (String, String, Bool) = {
            if matchingLabels.isEmpty == false {
                // If multiple labels map to the same surface (e.g. 来られる: potential/passive), do not guess.
                let baseLabel = matchingLabels.count == 1 ? matchingLabels[0] : matchingLabels.joined(separator: " / ")
                let structural = structuralBreakdown(for: matchingLabels, verbClass: verbClass, surface: surface)
                let funcText = functionSummary(for: matchingLabels)
                let display = structural.isEmpty ? baseLabel : "\(baseLabel)（\(structural)）"
                return (display, funcText, matchingLabels.count > 1)
            }

            // Fallback: use the deinflection trace if we have it, but mark uncertain.
            if resolvedDeinflectionTrace.isEmpty == false {
                let traceLabel = describeVerbishDeinflectionTrace(resolvedDeinflectionTrace)
                let display = traceLabel.isEmpty ? "(uncertain)" : "\(traceLabel)（uncertain）"
                return (display, "(uncertain)", true)
            }

            return ("(uncertain)", "(uncertain)", true)
        }()

        let pitchNote = "Pitch accent is shown for the lemma. The surface form may inherit it or be modified by attached auxiliaries; this view does not compute surface pitch from morae."

        return VerbMorphologyAnalysis(
            surface: surface,
            lemmaSurface: lemmaSurface,
            lemmaDisplay: lemmaDisplay,
            verbClass: verbClass,
            formDisplay: formDisplay,
            functionDisplay: functionDisplay,
            pitchNote: pitchNote,
            isUncertain: uncertain
        )
    }

    @MainActor
    private func updateHeaderLemmaAndFormLines() async {
        let surfaceText = resolvedSurfaceText
        guard surfaceText.isEmpty == false else {
            headerLemmaLine = nil
            headerFormLine = nil
            return
        }

        guard let lemmaTextRaw = resolvedLemmaText else {
            headerLemmaLine = nil
            headerFormLine = nil
            return
        }

        let lemmaText = lemmaTextRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lemmaText.isEmpty == false, lemmaText != surfaceText else {
            headerLemmaLine = nil
            headerFormLine = nil
            return
        }

        headerLemmaLine = "Lemma: \(lemmaText)"

        func friendlyDeinflectionReason(_ reason: String) -> String {
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            switch key {
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
            default:
                return trimmed.isEmpty ? reason : trimmed
            }
        }

        func describeTrace(_ trace: [Deinflector.AppliedRule]) -> String? {
            guard trace.isEmpty == false else { return nil }
            var ordered: [String] = []
            var seen = Set<String>()
            for step in trace {
                let label = friendlyDeinflectionReason(step.reason)
                if label.isEmpty { continue }
                if seen.insert(label).inserted {
                    ordered.append(label)
                }
            }
            guard ordered.isEmpty == false else { return nil }
            if ordered.count == 1 { return ordered[0] }
            return ordered.joined(separator: " → ")
        }

        if resolvedDeinflectionTrace.isEmpty == false {
            if let form = describeTrace(resolvedDeinflectionTrace) {
                headerFormLine = "Form: \(form) of \(lemmaText)"
                return
            }
        } else if let deinflector = try? Deinflector.loadBundled(named: "deinflect") {
            let candidates = deinflector.deinflect(surfaceText, maxDepth: 8, maxResults: 64)
            if let match = candidates.first(where: { $0.surface == lemmaText }) {
                if let form = describeTrace(match.trace) {
                    headerFormLine = "Form: \(form) of \(lemmaText)"
                    return
                }
            }
        }

        headerFormLine = "Form: inflected of \(lemmaText)"
    }

    // MARK: Definitions
    private func isCommonEntry(_ entry: DictionaryEntry) -> Bool {
        if let detail = entryDetails.first(where: { $0.entryID == entry.entryID }) {
            return detail.isCommon
        }
        return entry.isCommon
    }

    private func commonFirstStable(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.filter { isCommonEntry($0) } + entries.filter { isCommonEntry($0) == false }
    }

    private var definitionRows: [DefinitionRow] {
        let headword = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headword.isEmpty == false else { return [] }

        let isKanji = containsKanji(headword)
        let normalizedHeadword = kanaFoldToHiragana(headword)
        let contextKanaKey: String? = kana
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : kanaFoldToHiragana($0) }

        // Filter to entries relevant to the headword.
        let relevant: [DictionaryEntry] = entries.filter { entry in
            let k = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines)
            let r = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines)

            if isKanji {
                return k == headword
            }

            // Kana headword: include meanings for this kana, but do not display kanji spellings.
            if let r, r.isEmpty == false, kanaFoldToHiragana(r) == normalizedHeadword {
                return true
            }
            if k.isEmpty == false, kanaFoldToHiragana(k) == normalizedHeadword {
                return true
            }
            return false
        }

        let relevantOrdered = commonFirstStable(relevant)

        guard relevantOrdered.isEmpty == false else { return [] }

        if isKanji {
            // Rows per distinct kana reading, folding hiragana/katakana variants
            // of the same reading into a single bucket.
            struct Bucket {
                var firstIndex: Int
                var key: String
                var readings: [String]
                var entries: [DictionaryEntry]
            }
            var byReadingKey: [String: Bucket] = [:]
            for (idx, entry) in relevantOrdered.enumerated() {
                let raw = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard raw.isEmpty == false else { continue }
                let key = kanaFoldToHiragana(raw)
                if var existing = byReadingKey[key] {
                    existing.entries.append(entry)
                    if existing.readings.contains(raw) == false {
                        existing.readings.append(raw)
                    }
                    byReadingKey[key] = existing
                } else {
                    byReadingKey[key] = Bucket(firstIndex: idx, key: key, readings: [raw], entries: [entry])
                }
            }

            var orderedBuckets = Array(byReadingKey.values)
            orderedBuckets.sort { lhs, rhs in
                if let key = contextKanaKey {
                    let lhsMatch = lhs.key == key
                    let rhsMatch = rhs.key == key
                    if lhsMatch != rhsMatch { return lhsMatch }
                }
                return lhs.firstIndex < rhs.firstIndex
            }
            return orderedBuckets.compactMap { bucket in
                let pages = pagesForEntries(bucket.entries)
                guard pages.isEmpty == false else { return nil }
                let displayReading = preferredReading(from: bucket.readings) ?? bucket.readings.first ?? bucket.key
                return DefinitionRow(headword: headword, reading: displayReading, pages: pages)
            }
        } else {
            // Single kana row with all meanings.
            let pages = pagesForEntries(relevantOrdered)
            guard pages.isEmpty == false else { return [] }
            return [DefinitionRow(headword: headword, reading: headword, pages: pages)]
        }
    }

    private func pagesForEntries(_ entries: [DictionaryEntry]) -> [DefinitionPage] {
        let entries = commonFirstStable(entries)
        // Preserve first-seen ordering across all gloss parts.
        var order: [String] = []
        var buckets: [String: DictionaryEntry] = [:]

        for entry in entries {
            let detail = entryDetails.first(where: { $0.entryID == entry.entryID })
            let glossCandidates: [String] = {
                guard let detail else {
                    return glossParts(entry.gloss)
                }

                let orderedSenses = orderedSensesForDisplay(detail)
                var out: [String] = []
                out.reserveCapacity(min(12, orderedSenses.count))
                for sense in orderedSenses {
                    if let line = joinedGlossLine(for: sense)?.trimmingCharacters(in: .whitespacesAndNewlines), line.isEmpty == false {
                        out.append(line)
                    }
                }
                return out.isEmpty ? glossParts(entry.gloss) : out
            }()

            for gloss in glossCandidates {
                if buckets[gloss] == nil {
                    order.append(gloss)
                    buckets[gloss] = entry
                }
            }
        }

        return order.compactMap { gloss in
            guard let entry = buckets[gloss] else { return nil }
            return DefinitionPage(gloss: gloss, entry: entry)
        }
    }

    private func definitionRowView(_ row: DefinitionRow) -> some View {
        let reading = row.reading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReading = (reading?.isEmpty == false) ? reading : nil
        let isSaved = isSaved(surface: row.headword, kana: normalizedReading)
        let createdAt = isSaved ? savedWordCreatedAt(surface: row.headword, kana: normalizedReading) : nil

        let primaryGloss = row.pages.first?.gloss ?? ""
        let extraCount = max(0, row.pages.count - 1)
        let isExpanded = expandedDefinitionRowIDs.contains(row.id)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.headword)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)

                    if containsKanji(row.headword), let normalizedReading {
                        Text(normalizedReading)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let createdAt {
                        Text(createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button {
                        // Store meaning as the first page (best available summary).
                        toggleSaved(surface: row.headword, kana: normalizedReading, meaning: primaryGloss)
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .symbolRenderingMode(.hierarchical)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.thinMaterial, in: Circle())
                            .foregroundStyle(isSaved ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSaved ? "Saved" : "Save")

                    Button {
                        listAssignmentTarget = ListAssignmentTarget(surface: row.headword, kana: normalizedReading, meaning: primaryGloss)
                    } label: {
                        Image(systemName: "folder")
                            .symbolRenderingMode(.hierarchical)
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .background(.thinMaterial, in: Circle())
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Lists")
                }
            }
            // .modifier(dbgBG(LayoutDebugColor.DBG_PURPLE__DefinitionRowHeader))

            if primaryGloss.isEmpty == false {
                Text(primaryGloss)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    // .modifier(dbgBG(LayoutDebugColor.DBG_ORANGE__DefinitionGloss))
            }

            if isExpanded, row.pages.count > 1 {
                ForEach(Array(row.pages.dropFirst().prefix(12))) { page in
                    Text(page.gloss)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            if extraCount > 0 {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        if isExpanded {
                            expandedDefinitionRowIDs.remove(row.id)
                        } else {
                            expandedDefinitionRowIDs.insert(row.id)
                        }
                    }
                } label: {
                    Text(isExpanded ? "Hide" : "+\(extraCount) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                // .modifier(dbgBG(LayoutDebugColor.DBG_GRAY__DefinitionMore))
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        // .modifier(dbgBG(LayoutDebugColor.DBG_BLUE__DefinitionRow))
        // .modifier(dbgRowBG(LayoutDebugColor.DBG_BLUE__DefinitionRow))
    }

    // MARK: Full Entries
    private func entryDetailView(_ detail: DictionaryEntryDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            entryDetailHeader(detail)
                // .modifier(dbgBG(LayoutDebugColor.DBG_INDIGO__EntryHeader))

            if detail.senses.isEmpty == false {
                Divider()
                    .padding(.vertical, 2)

                let senses = orderedSensesForDisplay(detail)
                let showSenseNumbers = senses.count > 1
                ForEach(Array(senses.enumerated()), id: \.element.id) { index, sense in
                    senseView(sense, index: index + 1, showIndex: showSenseNumbers)
                    if index < senses.count - 1 {
                        Divider()
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(14)
        .background(
            .thinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        // .modifier(dbgBG(LayoutDebugColor.DBG_GREEN__FullEntryRow))
        // .modifier(dbgRowBG(LayoutDebugColor.DBG_GREEN__FullEntryRow))
    }

    private func entryDetailHeader(_ detail: DictionaryEntryDetail) -> some View {
        let headword = primaryHeadword(for: detail)
        let primaryReading = detail.kanaForms.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraKanjiForms = orderedUniqueForms(from: detail.kanjiForms).filter { $0 != headword }
        let extraKanaForms = orderedUniqueForms(from: detail.kanaForms).filter { $0 != (primaryReading ?? "") }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headword)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if detail.isCommon {
                    Text("Common")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }

            if let primaryReading, primaryReading.isEmpty == false {
                Text(primaryReading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if extraKanjiForms.isEmpty == false {
                Text("Kanji: \(extraKanjiForms.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if extraKanaForms.isEmpty == false {
                Text("Kana: \(extraKanaForms.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func senseView(_ sense: DictionaryEntrySense, index: Int, showIndex: Bool) -> some View {
        let glossLine = joinedGlossLine(for: sense)
        let noteLine = formattedSenseNotes(for: sense)

        return VStack(alignment: .leading, spacing: 6) {
            if let glossLine {
                if showIndex {
                    Text(numberedGlossText(index: index, gloss: glossLine, notes: noteLine))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(plainGlossText(gloss: glossLine, notes: noteLine))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if showIndex {
                    Text("\(index).")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.secondary)
                }
            }
            // .modifier(dbgBG(LayoutDebugColor.DBG_GRAY__SenseMeta))

            if let posLine = formattedTagsLine(from: sense.partsOfSpeech) {
                Text(posLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Notes are appended inline to the numbered gloss in parentheses.
        }
        // .modifier(dbgBG(LayoutDebugColor.DBG_PINK__SenseRow))
    }

    private func plainGlossText(gloss: String, notes: String?) -> AttributedString {
        var body = AttributedString(gloss)
        body.font = .body
        body.foregroundColor = .primary

        var result = body
        if let notes, notes.isEmpty == false {
            var suffix = AttributedString(" (\(notes))")
            suffix.font = .body
            suffix.foregroundColor = .primary
            result += suffix
        }
        return result
    }

    private func numberedGlossText(index: Int, gloss: String, notes: String?) -> AttributedString {
        // Keep number/tag/gloss visually identical so wrapping reads naturally.
        var prefix = AttributedString("\(index). ")
        prefix.font = .body
        prefix.foregroundColor = .primary

        var body = AttributedString(gloss)
        body.font = .body
        body.foregroundColor = .primary

        var result = prefix + body

        if let notes, notes.isEmpty == false {
            var suffix = AttributedString(" (\(notes))")
            suffix.font = .body
            suffix.foregroundColor = .primary
            result += suffix
        }

        return result
    }

    private func joinedGlossLine(for sense: DictionaryEntrySense) -> String? {
        func normalize(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let english = sense.glosses.filter { $0.language == "eng" || $0.language.isEmpty }
        let source = english.isEmpty ? sense.glosses : english
        let parts = source.map { normalize($0.text) }.filter { $0.isEmpty == false }
        guard parts.isEmpty == false else { return nil }
        return parts.joined(separator: "; ")
    }

    // MARK: POS-aware ranking
    private enum CoarseTokenPOS {
        case noun
        case verb
        case adjective
        case adverb
        case particle
        case auxiliary
        case other
    }

    private func coarseTokenPOS() -> CoarseTokenPOS? {
        let raw = (tokenPartOfSpeech ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return nil }

        // Mecab_Swift POS strings are typically like "名詞,一般,*,*".
        let head = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
        switch head {
        case "名詞": return .noun
        case "動詞": return .verb
        case "形容詞": return .adjective
        case "副詞": return .adverb
        case "助詞": return .particle
        case "助動詞": return .auxiliary
        default: return .other
        }
    }

    private func senseMatchesTokenPOS(_ sense: DictionaryEntrySense) -> Bool {
        guard let coarse = coarseTokenPOS() else { return false }
        guard sense.partsOfSpeech.isEmpty == false else { return false }

        func anyPrefix(_ prefixes: [String]) -> Bool {
            sense.partsOfSpeech.contains { tag in
                let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return prefixes.contains(where: { t.hasPrefix($0) })
            }
        }

        switch coarse {
        case .noun:
            return anyPrefix(["n", "pn"])
        case .verb:
            return anyPrefix(["v", "vs"])
        case .adjective:
            return anyPrefix(["adj"])
        case .adverb:
            return anyPrefix(["adv"])
        case .particle:
            return anyPrefix(["prt"])
        case .auxiliary:
            return anyPrefix(["aux"])
        case .other:
            return false
        }
    }

    private func orderedSensesForDisplay(_ detail: DictionaryEntryDetail) -> [DictionaryEntrySense] {
        guard detail.senses.isEmpty == false else { return [] }
        // If we don't have token POS, preserve JMdict order.
        guard coarseTokenPOS() != nil else {
            return detail.senses.sorted(by: { $0.orderIndex < $1.orderIndex })
        }

        return detail.senses.sorted { lhs, rhs in
            let lhsTier = senseMatchesTokenPOS(lhs) ? 0 : 1
            let rhsTier = senseMatchesTokenPOS(rhs) ? 0 : 1
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            if lhs.orderIndex != rhs.orderIndex { return lhs.orderIndex < rhs.orderIndex }
            return lhs.id < rhs.id
        }
    }

    private func primaryHeadword(for detail: DictionaryEntryDetail) -> String {
        if let kanji = detail.kanjiForms.first?.text, kanji.isEmpty == false {
            return kanji
        }
        if let kana = detail.kanaForms.first?.text, kana.isEmpty == false {
            return kana
        }
        return titleText
    }

    private func formsLine(label: String, forms: [DictionaryEntryForm], minimumCount: Int) -> String? {
        let values = orderedUniqueForms(from: forms)
        guard values.count >= minimumCount else { return nil }
        return "\(label): \(values.joined(separator: "、"))"
    }

    private func orderedUniqueForms(from forms: [DictionaryEntryForm]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for form in forms {
            let trimmed = form.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
    }

    private func formattedTagsLine(from tags: [String]) -> String? {
        guard tags.isEmpty == false else { return nil }
        return tags.joined(separator: " · ")
    }

    private func formattedSenseNotes(for sense: DictionaryEntrySense) -> String? {
        let raw = sense.miscellaneous + sense.fields + sense.dialects
        guard raw.isEmpty == false else { return nil }

        var seen: Set<String> = []
        var expanded: [String] = []
        for tag in raw {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.isEmpty == false else { continue }
            let value = expandSenseTag(normalized)
            let key = value.lowercased()
            if seen.insert(key).inserted {
                expanded.append(value)
            }
        }

        guard expanded.isEmpty == false else { return nil }
        return expanded.joined(separator: ", ")
    }

    private func expandSenseTag(_ tag: String) -> String {
        let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "uk": return "usually kana"
        case "arch": return "archaic"
        case "fem": return "feminine"
        case "obs": return "obsolete"
        case "col": return "colloquial"
        case "hon": return "honorific"
        case "hum": return "humble"
        case "pol": return "polite"
        case "sl": return "slang"
        case "vulg": return "vulgar"
        default: return tag
        }
    }

    // MARK: SQL Debug
    private var formattedDebugSQL: String {
        guard debugSQL.isEmpty == false else { return "" }
        return formatSQLDebug(debugSQL)
    }

    private func formatSQLDebug(_ value: String) -> String {
        let rawLines = value.components(separatedBy: CharacterSet.newlines)
        guard rawLines.isEmpty == false else { return value }

        // Separate metadata (e.g. "selectEntries term='...'" lines) from the SQL body so
        // indentation trimming doesn't get blocked by a header that has zero indent.
        let sqlStartKeywords: Set<String> = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "PRAGMA"]
        var headerLines: [String] = []
        var sqlLines: [String] = []
        var foundSQLStart = false
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if foundSQLStart == false,
            let firstWord = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first,
                sqlStartKeywords.contains(firstWord.uppercased()) {
                    foundSQLStart = true
                }

            if foundSQLStart {
                sqlLines.append(line)
            } else {
                headerLines.append(line)
            }
        }

        if sqlLines.isEmpty {
            sqlLines = rawLines
            headerLines = []
        }

        let nonEmptySQL = sqlLines.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
        guard nonEmptySQL.isEmpty == false else { return value }

        let leadingSpaceCounts: [Int] = nonEmptySQL.compactMap { line in
            var count = 0
            for ch in line {
                if ch == " " || ch == "\t" {
                    count += 1
                } else {
                    break
                }
            }
            return count
        }

        let minIndent = leadingSpaceCounts.min() ?? 0

        func trim(indent: Int, from line: String) -> String {
            guard indent > 0 else { return line }
            var remainingIndent = indent
            var result = ""
            var dropped = true
            for ch in line {
                if dropped, remainingIndent > 0, (ch == " " || ch == "\t") {
                    remainingIndent -= 1
                    continue
                }
                dropped = false
                result.append(ch)
            }
            return result
        }

        let normalizedSQL = sqlLines.map { line -> String in
            let trimmed = trim(indent: minIndent, from: line)
            return trimmed.trimmingCharacters(in: .whitespaces)
        }

        let collapsed = normalizedSQL.reduce(into: [String]()) { acc, line in
            if line.isEmpty {
                if acc.last?.isEmpty == false {
                    acc.append("")
                }
            } else {
                acc.append(line)
            }
        }

        var combined = headerLines + collapsed
        while combined.first?.isEmpty == true { combined.removeFirst() }
        while combined.last?.isEmpty == true { combined.removeLast() }
        return combined.joined(separator: "\n")
    }

    // MARK: Data Loading
    @MainActor
    private func load() async {
        let requestID = UUID()
        activeLoadRequestID = requestID

        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        var primaryTerms: [String] = []
        for t in [primary, secondary].compactMap({ $0 }) {
            guard t.isEmpty == false else { continue }
            if primaryTerms.contains(t) == false { primaryTerms.append(t) }
        }

        guard primaryTerms.isEmpty == false else {
            entries = []
            entryDetails = []
            return
        }

        isLoading = true
        errorMessage = nil
        entryDetails = []
        hasPitchAccentsTable = nil
        pitchAccentsForTerm = []
        isLoadingPitchAccents = true
        exampleSentences = []
        showAllExampleSentences = false
        isLoadingExampleSentences = true

        resolvedLemmaForLookup = nil
        resolvedDeinflectionTrace = []

        var merged: [DictionaryEntry] = []
        var seen: Set<String> = []
        var selectedLemmaUsedForLookup: String? = nil

        func selectedLemmaCandidate() -> String? {
            // Important: `lemmaCandidates` can include component/subtoken lemmas.
            // Only consider a lemma as a fallback when the surface/kana have no results.
            let raw = lemmaCandidates
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.isEmpty == false })
            guard let raw else { return nil }
            // For non-inflecting categories (particles/adverbs/nouns), lemma fallback
            // tends to add noise and can look unrelated.
            switch coarseTokenPOS() {
            case .verb?, .adjective?, .auxiliary?:
                return raw
            default:
                return nil
            }
        }

        do {
            for term in primaryTerms {
                try Task.checkCancellation()
                let keys = DictionaryKeyPolicy.keys(forDisplayKey: term)
                guard keys.lookupKey.isEmpty == false else { continue }
                let rows = try await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 100)
                for row in rows {
                    if seen.insert(row.id).inserted {
                        merged.append(row)
                    }
                }
            }

            // Only fall back to lemma if the surface/kana did not yield anything.
            if merged.isEmpty, let lemma = selectedLemmaCandidate() {
                if primaryTerms.contains(lemma) == false {
                    try Task.checkCancellation()
                    let keys = DictionaryKeyPolicy.keys(forDisplayKey: lemma)
                    if keys.lookupKey.isEmpty == false {
                        let rows = try await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 100)
                        for row in rows {
                            if seen.insert(row.id).inserted {
                                merged.append(row)
                            }
                        }
                        if rows.isEmpty == false {
                            selectedLemmaUsedForLookup = lemma
                        }
                    }
                }
            }

            // If we're still empty, attempt deinflection-based lemma lookup.
            // This is especially important for Words/History items saved as inflected surfaces.
            if merged.isEmpty {
                if let deinflector = try? Deinflector.loadBundled(named: "deinflect") {
                    // Prefer the explicit surface term; then try kana (if supplied).
                    for term in primaryTerms {
                        try Task.checkCancellation()
                        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { continue }

                        let candidates = deinflector.deinflect(trimmed, maxDepth: 8, maxResults: 64)
                        for cand in candidates {
                            if cand.trace.isEmpty { continue }
                            let keys = DictionaryKeyPolicy.keys(forDisplayKey: cand.baseForm)
                            guard keys.lookupKey.isEmpty == false else { continue }

                            let rows = try await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 100)
                            if rows.isEmpty == false {
                                for row in rows {
                                    if seen.insert(row.id).inserted {
                                        merged.append(row)
                                    }
                                }
                                resolvedLemmaForLookup = cand.baseForm
                                resolvedDeinflectionTrace = cand.trace
                                selectedLemmaUsedForLookup = cand.baseForm
                                break
                            }
                        }

                        if merged.isEmpty == false {
                            break
                        }
                    }
                }
            }

            guard activeLoadRequestID == requestID else { return }
            try Task.checkCancellation()

            // Display requirement: common entries should appear before non-common ones.
            // Preserve the existing relative order within each group.
            let mergedCommonFirst = merged.filter { $0.isCommon } + merged.filter { $0.isCommon == false }
            entries = mergedCommonFirst
            let details = await loadEntryDetails(for: mergedCommonFirst)

            guard activeLoadRequestID == requestID else { return }
            try Task.checkCancellation()

            let baseOrderedDetails: [DictionaryEntryDetail] = {
                // Keep any existing ordering, but optionally push POS-matching senses higher.
                if coarseTokenPOS() != nil {
                    return details.sorted { lhs, rhs in
                        let lhsTier = lhs.senses.contains(where: senseMatchesTokenPOS) ? 0 : 1
                        let rhsTier = rhs.senses.contains(where: senseMatchesTokenPOS) ? 0 : 1
                        if lhsTier != rhsTier { return lhsTier < rhsTier }
                        return lhs.entryID < rhs.entryID
                    }
                }
                return details
            }()
            // Final display requirement: common entries should all appear before non-common ones.
            entryDetails = baseOrderedDetails.filter { $0.isCommon } + baseOrderedDetails.filter { $0.isCommon == false }

            // If we did not resolve a lemma explicitly, treat the displayed term as the lemma.
            // (Used for morphology/pitch logic to avoid mixing surface/lemma in verb pages.)
            if resolvedLemmaForLookup == nil {
                let t = surface.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty == false {
                    resolvedLemmaForLookup = t
                }
            }

            // Pitch accents are an optional table. Load these after details so the page can render.
            let supportsPitchAccents = await DictionarySQLiteStore.shared.supportsPitchAccents()
            hasPitchAccentsTable = supportsPitchAccents

            if supportsPitchAccents {
                // Precompute lookup keys on the main actor to avoid Swift 6 isolation violations.
                let pitchPairs: [(surface: String, reading: String)] = {
                    let trimmedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedKana = (kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                    // If this is an inflected verb lookup, pitch accent must be associated with the lemma.
                    // Do not attempt to derive pitch from the surface form.
                    let lemmaForPitch = (resolvedLemmaForLookup ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let isInflectedVerbForPitch: Bool = {
                        guard isVerbLemma else { return false }
                        guard lemmaForPitch.isEmpty == false else { return false }
                        guard trimmedSurface.isEmpty == false else { return false }
                        return lemmaForPitch != trimmedSurface
                    }()

                    var pairs: [(String, String)] = []
                    func add(_ s: String, _ r: String) {
                        let s2 = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        let r2 = r.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard s2.isEmpty == false, r2.isEmpty == false else { return }
                        pairs.append((s2, r2))
                    }

                    if isInflectedVerbForPitch == false {
                        if trimmedSurface.isEmpty == false, trimmedKana.isEmpty == false {
                            add(trimmedSurface, trimmedKana)
                        }
                        if trimmedSurface.isEmpty == false {
                            add(trimmedSurface, trimmedSurface)
                        }
                        if trimmedKana.isEmpty == false {
                            add(trimmedKana, trimmedKana)
                        }
                    }

                    // Always prefer lemma entry spellings/readings from JMdict details.
                    for detail in entryDetails {
                        let headword = primaryHeadword(for: detail)
                        let reading = (detail.kanaForms.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if headword.isEmpty == false, reading.isEmpty == false {
                            add(headword, reading)
                        }
                        if reading.isEmpty == false {
                            add(reading, reading)
                        }
                    }

                    // De-dupe while preserving order.
                    var seen = Set<String>()
                    var out: [(surface: String, reading: String)] = []
                    for (s, r) in pairs {
                        let key = "\(s)|\(r)"
                        if seen.insert(key).inserted {
                            out.append((s, r))
                        }
                    }
                    return out
                }()

                let pitchRows: [PitchAccent] = await Task.detached(priority: .userInitiated) {
                    var seen = Set<String>()
                    var out: [PitchAccent] = []
                    out.reserveCapacity(8)

                    for pair in pitchPairs {
                        let rows = (try? await DictionarySQLiteStore.shared.fetchPitchAccents(surface: pair.surface, reading: pair.reading)) ?? []
                        for row in rows {
                            let key = "\(row.surface)|\(row.reading)|\(row.accent)|\(row.morae)|\(row.kind ?? "")|\(row.readingMarked ?? "")"
                            if seen.insert(key).inserted {
                                out.append(row)
                            }
                        }
                    }

                    out.sort {
                        if $0.accent != $1.accent { return $0.accent < $1.accent }
                        if $0.morae != $1.morae { return $0.morae < $1.morae }
                        return ($0.kind ?? "") < ($1.kind ?? "")
                    }
                    return out
                }.value

                guard activeLoadRequestID == requestID else { return }
                pitchAccentsForTerm = pitchRows
            } else {
                pitchAccentsForTerm = []
            }
            isLoadingPitchAccents = false

            // If we weren't invoked with component parts from Paste, infer a reasonable component
            // breakdown for compounds.
            await inferTokenPartsIfNeeded()

            guard activeLoadRequestID == requestID else { return }
            try Task.checkCancellation()

            // Example sentences are substring-matched. Prefer surface/lemma terms before kana so
            // the initial terms don't get dominated by broad kana matches.
            let sentencePrimaryTerms: [String] = {
                var ordered: [String] = []
                func add(_ value: String?) {
                    guard let value else { return }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { return }
                    if ordered.contains(trimmed) == false { ordered.append(trimmed) }
                }
                add(primary)
                add(selectedLemmaUsedForLookup)
                add(secondary)
                return ordered
            }()

            let sentenceTerms = sentenceLookupTerms(primaryTerms: sentencePrimaryTerms, entryDetails: details)
            do {
                let sentences = try await DictionarySQLiteStore.shared.fetchExampleSentences(containing: sentenceTerms, limit: 8)
                exampleSentences = sentences.sorted { lhs, rhs in
                    let ls = exampleSentenceComplexityScore(lhs)
                    let rs = exampleSentenceComplexityScore(rhs)
                    if ls != rs { return ls < rs }
                    // Stable-ish tie-breakers.
                    if lhs.jpText.count != rhs.jpText.count { return lhs.jpText.count < rhs.jpText.count }
                    return lhs.id < rhs.id
                }
            } catch {
                exampleSentences = []
            }
            isLoadingExampleSentences = false

            isLoading = false
            debugSQL = await DictionarySQLiteStore.shared.debugLastQueryDescription()
        } catch is CancellationError {
            // No-op: a new lookup superseded this one.
            return
        } catch {
            guard activeLoadRequestID == requestID else { return }
            entries = []
            entryDetails = []
            hasPitchAccentsTable = nil
            pitchAccentsForTerm = []
            isLoadingPitchAccents = false
            exampleSentences = []
            isLoadingExampleSentences = false
            isLoading = false
            errorMessage = String(describing: error)
        }
    }

    // MARK: Morphology helpers (verbs only)
    private func describeVerbishDeinflectionTrace(_ trace: [Deinflector.AppliedRule]) -> String {
        guard trace.isEmpty == false else { return "" }
        var ordered: [String] = []
        var seen = Set<String>()

        func add(_ label: String) {
            let t = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.isEmpty == false else { return }
            if seen.insert(t).inserted { ordered.append(t) }
        }

        for step in trace {
            switch step.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "-te": add("て-form")
            case "-ta", "past": add("past")
            case "negative": add("negative")
            case "polite": add("polite")
            case "potential": add("potential")
            case "passive": add("passive")
            case "causative": add("causative")
            case "volitional": add("volitional")
            case "imperative": add("imperative")
            case "conditional": add("conditional")
            default:
                break
            }
        }
        return ordered.joined(separator: " → ")
    }

    private func structuralBreakdown(
        for labels: [String],
        verbClass: JapaneseVerbConjugator.VerbClass,
        surface: String
    ) -> String {
        // Do not guess if multiple labels conflict.
        if labels.count != 1 {
            return ""
        }

        let label = labels[0]
        let endsWithTeDe = surface.hasSuffix("で") ? "で" : (surface.hasSuffix("て") ? "て" : nil)
        let endsWithTaDa = surface.hasSuffix("だ") ? "だ" : (surface.hasSuffix("た") ? "た" : nil)

        switch label {
        case "て-form":
            if let td = endsWithTeDe { return "連用形 + \(td)" }
            return "連用形 + て"
        case "Past (た)":
            if let td = endsWithTaDa { return "連用形 + \(td)" }
            return "連用形 + た"
        case "Negative (ない)":
            return "未然形 + ない"
        case "Polite (ます)":
            return "連用形 + ます"
        case "Progressive (ている)":
            return "て-form + いる"
        case "Potential":
            switch verbClass {
            case .godan:
                return "可能形（え段 + る）"
            case .ichidan:
                return "未然形 + られる"
            case .suru:
                return "できる"
            case .kuru:
                return "こられる"
            }
        case "Passive":
            switch verbClass {
            case .godan:
                return "未然形 + れる"
            case .ichidan:
                return "未然形 + られる"
            case .suru:
                return "される"
            case .kuru:
                // Passive for 来る is not typically used; avoid guessing.
                return ""
            }
        case "Causative":
            switch verbClass {
            case .godan:
                return "未然形 + せる"
            case .ichidan:
                return "未然形 + させる"
            case .suru:
                return "させる"
            case .kuru:
                return "こさせる"
            }
        case "Volitional":
            switch verbClass {
            case .godan:
                return "意向形（お段 + う）"
            case .ichidan:
                return "意向形（よう）"
            case .suru:
                return "しよう"
            case .kuru:
                return "こよう"
            }
        case "Imperative", "Imperative (alt)":
            return "命令形"
        case "Conditional (ば)":
            return "仮定形 + ば"
        case "Conditional (たら)":
            return "過去形 + ら"
        case "Prohibitive":
            return "終止形 + な"
        case "Desire (たい)":
            return "連用形 + たい"
        default:
            return ""
        }
    }

    private func functionSummary(for labels: [String]) -> String {
        // If multiple labels match, we can only state that the function is ambiguous.
        guard labels.count == 1 else {
            return "(uncertain: multiple analyses match this surface)"
        }

        switch labels[0] {
        case "て-form": return "Clause chaining / auxiliary attachment"
        case "Past (た)": return "Past / perfective"
        case "Negative (ない)": return "Negation"
        case "Polite (ます)": return "Politeness"
        case "Progressive (ている)": return "Progressive / resulting state"
        case "Potential": return "Ability / possibility"
        case "Passive": return "Passive"
        case "Causative": return "Causation"
        case "Volitional": return "Volition / invitation"
        case "Imperative", "Imperative (alt)": return "Command"
        case "Conditional (ば)": return "Conditional"
        case "Conditional (たら)": return "Conditional / temporal sequence"
        case "Prohibitive": return "Prohibition"
        case "Desire (たい)": return "Desire"
        default:
            return "(uncertain)"
        }
    }

    private func verbClassDisplayName(_ cls: JapaneseVerbConjugator.VerbClass) -> String {
        switch cls {
        case .godan:
            return "Godan"
        case .ichidan:
            return "Ichidan"
        case .suru:
            return "Irregular (する)"
        case .kuru:
            return "Irregular (来る)"
        }
    }


    private func refreshContextInsights() {
        let sentence = contextSentence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sentence, sentence.isEmpty == false {
            detectedGrammar = GrammarPatternDetector.detect(in: sentence)
        } else {
            detectedGrammar = []
        }

        let headword = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = (lemmaCandidates.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) ?? headword
        similarWords = JapaneseSimilarityService.neighbors(for: seed, maxCount: 12)
            .filter { $0 != seed }
    }

    private func sentenceLookupTerms(primaryTerms: [String], entryDetails: [DictionaryEntryDetail]) -> [String] {
        let shouldSuppressComponentTerms = tokenParts.count > 1
        let partTerms: Set<String> = {
            guard shouldSuppressComponentTerms else { return [] }
            var s: Set<String> = []
            for part in tokenParts {
                let surface = part.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                if surface.isEmpty == false { s.insert(surface) }
                if let kana = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines), kana.isEmpty == false { s.insert(kana) }
            }
            return s
        }()

        var out: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            // Avoid pulling in examples for component terms of a compound (e.g. 思考 + 回路).
            if shouldSuppressComponentTerms, partTerms.contains(trimmed) { return }
            if out.contains(trimmed) == false { out.append(trimmed) }
        }

        for term in primaryTerms {
            add(term)
        }

        if let first = entryDetails.first {
            add(primaryHeadword(for: first))
            if let reading = first.kanaForms.first?.text {
                add(reading)
            }
        }

        return out
    }

    // MARK: Example sentence sorting
    private func exampleSentenceComplexityScore(_ sentence: ExampleSentence) -> Int {
        // Heuristic: simpler sentences tend to be shorter with fewer kanji and less punctuation.
        var kanjiCount = 0
        var punctuationCount = 0
        var digitCount = 0

        for scalar in sentence.jpText.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF: // CJK
                kanjiCount += 1
            case 0x0030...0x0039: // digits
                digitCount += 1
            case 0x3001, 0x3002, 0xFF01, 0xFF1F, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B:
                punctuationCount += 1
            default:
                if CharacterSet.punctuationCharacters.contains(scalar) {
                    punctuationCount += 1
                }
            }
        }

        let length = sentence.jpText.count

        // Weighting: kanji and punctuation add more "complexity" than raw length.
        return (length * 2) + (kanjiCount * 6) + (punctuationCount * 4) + (digitCount * 2)
    }

    private func exampleSentenceRow(_ sentence: ExampleSentence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            interactiveSentenceLine(
                sentence.jpText,
                mode: .japanese,
                highlightTerms: japaneseHighlightTermsForSentences(),
                contextSentenceForOpen: sentence.jpText,
                sentenceIDForPopoverAnchoring: sentence.id
            )
            interactiveSentenceLine(
                sentence.enText,
                mode: .english,
                highlightTerms: [],
                contextSentenceForOpen: sentence.jpText,
                sentenceIDForPopoverAnchoring: sentence.id
            )
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func interactiveSentenceLine(
        _ text: String,
        mode: DictionarySearchMode,
        highlightTerms: [String],
        contextSentenceForOpen: String?,
        sentenceIDForPopoverAnchoring: String?
    ) -> some View {
        if #available(iOS 16.0, *) {
            let segments = sentenceSegments(for: text, mode: mode)
            let englishRanges: [NSRange] = (mode == .english) ? englishHighlightRanges(in: text) : []
            InlineWrapLayout(spacing: 0, lineSpacing: 6) {
                ForEach(segments) { seg in
                    if seg.isToken {
                        let popoverTokenID: String = {
                            let modeKey: String = (mode == .english) ? "en" : "jp"
                            let sentenceKey = sentenceIDForPopoverAnchoring ?? "unknown"
                            return "tok|\(sentenceKey)|\(modeKey)|\(seg.range.location)|\(seg.range.length)"
                        }()

                        Button {
                            presentTokenPopover(id: popoverTokenID, text: seg.text, mode: mode, contextSentence: contextSentenceForOpen)
                        } label: {
                            Text(seg.text)
                                .foregroundStyle(tokenForeground(for: seg, mode: mode, highlightTerms: highlightTerms, englishHighlightRanges: englishRanges))
                        }
                        .buttonStyle(.plain)
                        .popover(
                            item: Binding<ActiveToken?>(
                                get: {
                                    guard let t = activeToken, t.id == popoverTokenID else { return nil }
                                    return t
                                },
                                set: { newValue in
                                    // Only clear if this token is the active one.
                                    if newValue == nil, activeToken?.id == popoverTokenID {
                                        activeToken = nil
                                    } else {
                                        activeToken = newValue
                                    }
                                }
                            )
                        ) { token in
                            tokenPopoverView(token)
                                .presentationCompactAdaptation(.popover)
                        }
                    } else {
                        Text(seg.text)
                            .foregroundStyle(tokenForeground(for: seg, mode: mode, highlightTerms: highlightTerms, englishHighlightRanges: englishRanges))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            if mode == .japanese {
                Text(highlightedJapaneseSentence(text))
            } else {
                Text(highlightedEnglishSentence(text))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct SentenceSegment: Identifiable, Hashable {
        let id: String
        let text: String
        let isToken: Bool
        let range: NSRange
    }

    private func sentenceSegments(for sentence: String, mode: DictionarySearchMode) -> [SentenceSegment] {
        let s = sentence
        let ns = s as NSString
        guard ns.length > 0 else { return [] }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        switch mode {
        case .japanese:
            tokenizer.setLanguage(.japanese)
        case .english:
            tokenizer.setLanguage(.english)
        }

        var tokenRanges: [NSRange] = []
        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            let r = NSRange(range, in: s)
            if r.location != NSNotFound, r.length > 0 {
                tokenRanges.append(r)
            }
            return true
        }
        tokenRanges.sort { $0.location < $1.location }

        if tokenRanges.isEmpty {
            return [SentenceSegment(id: "seg:0:\(ns.length)", text: s, isToken: false, range: NSRange(location: 0, length: ns.length))]
        }

        var out: [SentenceSegment] = []
        out.reserveCapacity(tokenRanges.count * 2)

        var cursor = 0
        for r in tokenRanges {
            if r.location > cursor {
                let gap = ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
                if gap.isEmpty == false {
                    out.append(SentenceSegment(id: "seg:\(cursor):\(r.location - cursor)", text: gap, isToken: false, range: NSRange(location: cursor, length: r.location - cursor)))
                }
            }

            let tokenText = ns.substring(with: r)
            if isEligibleTapToken(tokenText) {
                out.append(SentenceSegment(id: "seg:\(r.location):\(r.length)", text: tokenText, isToken: true, range: r))
            } else {
                out.append(SentenceSegment(id: "seg:\(r.location):\(r.length)", text: tokenText, isToken: false, range: r))
            }

            cursor = NSMaxRange(r)
        }

        if cursor < ns.length {
            let tail = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            if tail.isEmpty == false {
                out.append(SentenceSegment(id: "seg:\(cursor):\(ns.length - cursor)", text: tail, isToken: false, range: NSRange(location: cursor, length: ns.length - cursor)))
            }
        }

        return out
    }

    private func isEligibleTapToken(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }

        // Filter out pure punctuation.
        let scalars = trimmed.unicodeScalars
        guard scalars.isEmpty == false else { return false }
        let punct = CharacterSet.punctuationCharacters
        let punctCount = scalars.filter { punct.contains($0) }.count
        if punctCount == scalars.count { return false }
        return true
    }

    private func tokenForeground(
        for segment: SentenceSegment,
        mode: DictionarySearchMode,
        highlightTerms: [String],
        englishHighlightRanges: [NSRange]
    ) -> Color {
        let base: Color = (mode == .english) ? .secondary : Color(uiColor: .secondaryLabel)

        if mode == .english {
            guard englishHighlightRanges.isEmpty == false else { return base }
            if englishHighlightRanges.contains(where: { NSIntersectionRange($0, segment.range).length > 0 }) {
                return Color(uiColor: .systemOrange)
            }
            return base
        }

        guard highlightTerms.isEmpty == false else { return base }
        if highlightTerms.contains(where: { segment.text.contains($0) }) {
            return Color(uiColor: .systemOrange)
        }
        return base
    }

    private func presentTokenPopover(id: String, text: String, mode: DictionarySearchMode, contextSentence: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

        activeTokenLookupResult = nil
        isLoadingActiveTokenLookup = true
        let token = ActiveToken(id: id, text: trimmed, mode: mode, contextSentence: contextSentence)
        activeToken = token

        Task {
            let id = token.id
            defer {
                if activeToken?.id == id {
                    isLoadingActiveTokenLookup = false
                }
            }

            let keys = DictionaryKeyPolicy.keys(forDisplayKey: trimmed)
            guard keys.lookupKey.isEmpty == false else {
                if activeToken?.id == id {
                    activeTokenLookupResult = nil
                }
                return
            }

            let rows: [DictionaryEntry] = (try? await Task.detached(priority: .userInitiated) {
                try await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 10, mode: mode)
            }.value) ?? []

            if activeToken?.id == id {
                activeTokenLookupResult = rows.first
            }
        }
    }

    private func tokenPopoverView(_ token: ActiveToken) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(token.text)
                .font(.headline)
                .lineLimit(2)

            if isLoadingActiveTokenLookup {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking up…")
                        .foregroundStyle(.secondary)
                }
            } else if let entry = activeTokenLookupResult {
                let head = entry.kanji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (entry.kana ?? token.text) : entry.kanji
                VStack(alignment: .leading, spacing: 6) {
                    Text(head)
                        .font(.subheadline.weight(.semibold))

                    if let kana = entry.kana,
                       kana.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                       kana != head {
                        Text(kana)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView(.vertical) {
                        Text(firstGloss(for: entry.gloss))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 140)

                    Button {
                        activeToken = nil
                        DispatchQueue.main.async {
                            navigationTarget = NavigationTarget(surface: head, kana: entry.kana, contextSentence: token.contextSentence)
                        }
                    } label: {
                        Label("Open entry", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("No dictionary results.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func highlightedEnglishSentence(_ sentence: String) -> AttributedString {
        let s = sentence
        guard s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return AttributedString(sentence) }

        let ranges = englishHighlightRanges(in: s)
        guard ranges.isEmpty == false else { return AttributedString(sentence) }

        let ns = s as NSString
        let mutable = NSMutableAttributedString(string: s)
        let baseColor = UIColor.secondaryLabel
        let highlightColor = UIColor.systemOrange
        mutable.addAttribute(.foregroundColor, value: baseColor, range: NSRange(location: 0, length: ns.length))

        for r in ranges {
            guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= ns.length else { continue }
            mutable.addAttribute(.foregroundColor, value: highlightColor, range: r)
        }

        return AttributedString(mutable)
    }

    private var displayTokenParts: [TokenPart] {
        if tokenParts.count > 1 { return tokenParts }
        return inferredTokenParts
    }

    private func inferTokenPartsIfNeeded() async {
        guard tokenParts.count <= 1 else {
            inferredTokenParts = []
            return
        }
        guard inferredTokenParts.isEmpty else { return }

        // Prefer the user-selected surface for component splitting.
        // Using the dictionary's primary headword can swap kana selections into kanji,
        // which makes the Components display feel wrong (e.g. いつだって → 何時だって).
        let headword: String = {
            let selected = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            if selected.isEmpty == false, containsJapaneseScript(selected) {
                return selected
            }
            if let first = entryDetails.first {
                let fromDict = primaryHeadword(for: first).trimmingCharacters(in: .whitespacesAndNewlines)
                if fromDict.isEmpty == false { return fromDict }
            }
            return titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        }()

        guard headword.isEmpty == false else { return }
        guard containsKanji(headword) || containsJapaneseScript(headword) else { return }

        func composedCharacterRanges(for text: String) -> [NSRange] {
            let ns = text as NSString
            guard ns.length > 0 else { return [] }
            var ranges: [NSRange] = []
            ranges.reserveCapacity(min(ns.length, 16))
            var i = 0
            while i < ns.length {
                let r = ns.rangeOfComposedCharacterSequence(at: i)
                if r.length <= 0 { break }
                ranges.append(r)
                i = NSMaxRange(r)
            }
            return ranges
        }

        func lookupReading(surface: String) async -> String? {
            let keys = DictionaryKeyPolicy.keys(forDisplayKey: surface)
            guard keys.lookupKey.isEmpty == false else { return nil }
            let rows: [DictionaryEntry] = (try? await DictionarySQLiteStore.shared.lookupExact(term: keys.lookupKey, limit: 1, mode: .japanese)) ?? []
            return rows.first?.kana
        }

        func setFromSpans(_ spans: [TextSpan], headword: String) async {
            // Ensure spans fully cover the string contiguously.
            let ns = headword as NSString
            let sorted = spans.sorted { $0.range.location < $1.range.location }
            guard sorted.first?.range.location == 0 else { return }

            var cursor = 0
            for sp in sorted {
                if sp.range.location != cursor { return }
                cursor = NSMaxRange(sp.range)
            }
            guard cursor == ns.length else { return }

            var out: [TokenPart] = []
            out.reserveCapacity(min(sorted.count, 8))

            for (idx, sp) in sorted.enumerated() {
                if idx >= 8 { break }
                let surface = sp.surface.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard surface.isEmpty == false else { continue }
                let reading = await lookupReading(surface: surface)
                out.append(TokenPart(id: "infer:\(sp.range.location):\(sp.range.length)", surface: surface, kana: reading))
            }

            if out.count > 1 {
                inferredTokenParts = out
            }
        }

        do {
            let spans = try await SegmentationService.shared.segment(text: headword)
            if spans.count > 1 {
                await setFromSpans(spans, headword: headword)
                return
            }

            // Fallback: try a 2-part split that yields dictionary hits on both sides.
            // This helps when the lexicon contains the full compound as one token.
            let charRanges = composedCharacterRanges(for: headword)
            guard charRanges.count >= 2, charRanges.count <= 10 else { return }
            let ns = headword as NSString

            var bestSplit: (idx: Int, score: Int, left: String, right: String, leftReading: String?, rightReading: String?)? = nil
            for splitIdx in 1..<(charRanges.count) {
                let leftRange = NSRange(location: 0, length: charRanges[splitIdx].location)
                let rightRange = NSRange(location: charRanges[splitIdx].location, length: ns.length - charRanges[splitIdx].location)
                guard leftRange.length > 0, rightRange.length > 0 else { continue }

                let left = ns.substring(with: leftRange).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let right = ns.substring(with: rightRange).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard left.isEmpty == false, right.isEmpty == false else { continue }

                let leftReading = await lookupReading(surface: left)
                let rightReading = await lookupReading(surface: right)
                guard leftReading != nil || rightReading != nil else { continue }

                // Score: prefer both sides having hits, then more balanced splits.
                let both = (leftReading != nil && rightReading != nil) ? 10_000 : 0
                let balance = min(left.count, right.count) * 100
                let score = both + balance
                if let best = bestSplit {
                    if score > best.score {
                        bestSplit = (splitIdx, score, left, right, leftReading, rightReading)
                    }
                } else {
                    bestSplit = (splitIdx, score, left, right, leftReading, rightReading)
                }
            }

            if let bestSplit {
                inferredTokenParts = [
                    TokenPart(id: "infer:split:left", surface: bestSplit.left, kana: bestSplit.leftReading),
                    TokenPart(id: "infer:split:right", surface: bestSplit.right, kana: bestSplit.rightReading)
                ]
            }
        } catch {
            // best-effort only
        }
    }

    private func containsJapaneseScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x309F, // Hiragana
                 0x30A0...0x30FF, // Katakana
                 0xFF66...0xFF9F, // Half-width katakana
                 0x3400...0x4DBF, // CJK Ext A
                 0x4E00...0x9FFF: // CJK Unified
                return true
            default:
                continue
            }
        }
        return false
    }

    private func partOfSpeechSummaryLine() -> String? {
        // Prefer JMdict POS tags; fall back to MeCab POS if we have nothing else.
        let posTags: [String] = {
            var seen: Set<String> = []
            var out: [String] = []
            for detail in entryDetails {
                for sense in detail.senses {
                    for tag in sense.partsOfSpeech {
                        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.isEmpty == false else { continue }
                        let expanded = expandPartOfSpeechTag(trimmed)
                        let key = expanded.lowercased()
                        if seen.insert(key).inserted {
                            out.append(expanded)
                        }
                        if out.count >= 8 { break }
                    }
                    if out.count >= 8 { break }
                }
                if out.count >= 8 { break }
            }
            return out
        }()

        if posTags.isEmpty == false {
            return "Part of speech: \(posTags.joined(separator: " · "))"
        }

        let mecab = (tokenPartOfSpeech ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if mecab.isEmpty == false {
            return "Part of speech: \(mecab)"
        }
        return nil
    }

    private func expandPartOfSpeechTag(_ tag: String) -> String {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch t {
        case "n": return "noun"
        case "pn": return "pronoun"
        case "adj-i": return "i-adjective"
        case "adj-na": return "na-adjective"
        case "adj-no": return "no-adjective"
        case "adj-pn": return "pre-noun adjectival"
        case "adv": return "adverb"
        case "prt": return "particle"
        case "conj": return "conjunction"
        case "int": return "interjection"
        case "num": return "numeric"
        case "aux": return "auxiliary"
        case "exp": return "expression"
        case "pref": return "prefix"
        case "suf": return "suffix"
        case "vs": return "suru verb"
        case "vk": return "kuru verb"
        case "vz": return "zuru verb"
        case "v1": return "ichidan verb"
        default:
            if t.hasPrefix("v5") { return "godan verb"
            }
            return tag
        }
    }

    // MARK: Verb conjugations
    private var shouldShowVerbConjugations: Bool {
        guard entryDetails.isEmpty == false else { return false }
        guard verbConjugationVerbClass != nil else { return false }
        guard verbConjugationBaseForm.isEmpty == false else { return false }
        return true
    }

    private var verbConjugationHeaderLine: String? {
        guard let verbClass = verbConjugationVerbClass else { return nil }
        let cls: String
        switch verbClass {
        case .ichidan: cls = "ichidan"
        case .godan: cls = "godan"
        case .suru: cls = "suru"
        case .kuru: cls = "kuru"
        }
        return "Based on lemma: \(verbConjugationBaseForm) (\(cls) verb)"
    }

    private var verbConjugationBaseForm: String {
        let lemma = (resolvedLemmaText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if lemma.isEmpty == false { return lemma }
        return titleText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var verbConjugationVerbClass: JapaneseVerbConjugator.VerbClass? {
        let tags = verbPosTags
        return JapaneseVerbConjugator.detectVerbClass(fromJMDictPosTags: tags)
    }

    private var verbPosTags: [String] {
        var out: [String] = []
        var seen = Set<String>()
        for detail in entryDetails {
            for sense in detail.senses {
                for tag in sense.partsOfSpeech {
                    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { continue }
                    let key = trimmed.lowercased()
                    if seen.insert(key).inserted {
                        out.append(trimmed)
                    }
                }
            }
        }
        return out
    }

    private func verbConjugations(set: JapaneseVerbConjugator.ConjugationSet) -> [JapaneseVerbConjugation] {
        guard let verbClass = verbConjugationVerbClass else { return [] }
        return JapaneseVerbConjugator.conjugations(for: verbConjugationBaseForm, verbClass: verbClass, set: set)
    }

    private func japaneseHighlightTermsForSentences() -> [String] {
        // Keep aligned with `highlightedJapaneseSentence` behavior.
        let lookupAligned = sentenceLookupTerms(primaryTerms: [surface, kana].compactMap { $0 }, entryDetails: entryDetails)
        return lookupAligned
    }

    private func englishHighlightRanges(in sentence: String) -> [NSRange] {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false else { return [] }

        let candidates = englishGlossPhraseCandidates()
        guard candidates.isEmpty == false else { return [] }

        // Choose the "best" phrase that actually appears in the sentence.
        // Preference order:
        // - more words (multi-word phrases are more aligned)
        // - longer phrase
        // - earlier occurrence
        var best: (phrase: String, regex: NSRegularExpression, score: Int, firstLocation: Int)? = nil

        for phrase in candidates {
            guard let regex = englishPhraseRegex(for: phrase) else { continue }
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            guard matches.isEmpty == false else { continue }

            let words = phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).count
            let score = (words * 10_000) + min(phrase.count, 1000)
            let firstLoc = matches.first?.range.location ?? Int.max
            if let b = best {
                if score > b.score || (score == b.score && firstLoc < b.firstLocation) {
                    best = (phrase, regex, score, firstLoc)
                }
            } else {
                best = (phrase, regex, score, firstLoc)
            }
        }

        if let best {
            let ns = s as NSString
            let range = NSRange(location: 0, length: ns.length)
            return best.regex.matches(in: s, range: range).map { $0.range }.filter { $0.length > 0 }
        }

        // Fallback: if no gloss phrase appears verbatim in the translation (e.g. “police” vs “cops”),
        // use Apple’s English word embedding to highlight semantically-near tokens.
        return englishEmbeddingHighlightRanges(in: s)
    }

    private func englishEmbeddingHighlightRanges(in sentence: String) -> [NSRange] {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false else { return [] }

        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return [] }

        let keywords = englishGlossKeywordCandidates(maxCount: 36)
        guard keywords.isEmpty == false else { return [] }
        let keywordSet = Set(keywords)

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = s
        tokenizer.setLanguage(.english)

        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct TokenInfo {
            let range: NSRange
            let text: String
            let normalized: String
        }

        struct ScoredRange {
            let range: NSRange
            let distance: Double
            let token: String
            let tokenIndex: Int
        }

        // Use embedding distance rather than neighbors() membership.
        // This is more stable for cases like “miss” vs “missed” and “old” (from gloss parentheses).
        let distanceThreshold: Double = 0.52
        let maxHighlights = 2

        let negationTokens: Set<String> = [
            "not", "no", "never", "dont", "don't", "cant", "can't", "cannot",
            "wont", "won't", "wouldnt", "wouldn't", "shouldnt", "shouldn't",
            "couldnt", "couldn't", "didnt", "didn't", "doesnt", "doesn't",
            "isnt", "isn't", "arent", "aren't", "wasnt", "wasn't", "werent", "weren't",
            "without"
        ]

        func englishLemma(for word: String) -> String? {
            let w = word.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard w.isEmpty == false else { return nil }
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = w
            // Use the stable overload available across iOS 15/16 SDKs.
            let result = tagger.tag(at: w.startIndex, unit: .word, scheme: .lemma)
            let lemma = result.0?.rawValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
            return lemma.isEmpty ? nil : lemma
        }

        func bestDistance(for token: String) -> Double? {
            let normalized = normalizeEnglishWord(token)
            guard normalized.isEmpty == false else { return nil }
            if englishStopwords.contains(normalized) { return nil }
            if normalized.count < 3 { return nil }

            // Fast exact match path.
            if keywordSet.contains(normalized) { return 0 }

            let lemma = englishLemma(for: normalized).map { normalizeEnglishWord($0) }
            if let lemma, lemma.isEmpty == false, keywordSet.contains(lemma) { return 0 }

            var forms: [String] = [normalized]
            if let lemma, lemma.isEmpty == false, lemma != normalized { forms.append(lemma) }

            // Simple morphology helpers: plural/ed/ing.
            if normalized.hasSuffix("s"), normalized.count > 3 {
                forms.append(String(normalized.dropLast()))
            }
            if normalized.hasSuffix("ed"), normalized.count > 4 {
                forms.append(String(normalized.dropLast(2)))
            }
            if normalized.hasSuffix("ing"), normalized.count > 5 {
                forms.append(String(normalized.dropLast(3)))
            }

            var best: Double? = nil
            for f in forms {
                for kw in keywords {
                    if f == kw { return 0 }
                    let d = embedding.distance(between: f, and: kw)
                    guard d.isFinite else { continue }
                    if let b = best {
                        if d < b { best = d }
                    } else {
                        best = d
                    }
                }
            }
            return best
        }

        var tokens: [TokenInfo] = []
        tokens.reserveCapacity(24)

        var scored: [ScoredRange] = []
        scored.reserveCapacity(12)

        func isNegationToken(_ raw: String) -> Bool {
            let n = normalizeEnglishWord(raw)
            if n.isEmpty { return false }
            if negationTokens.contains(n) { return true }
            // Handle unicode apostrophe variants by removing apostrophes.
            let stripped = n.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            return negationTokens.contains(stripped)
        }

        tokenizer.enumerateTokens(in: s.startIndex..<s.endIndex) { range, _ in
            let r = NSRange(range, in: s)
            if r.location == NSNotFound || r.length <= 0 || NSMaxRange(r) > ns.length {
                return true
            }

            let tokenText = ns.substring(with: r)
            let normalized = normalizeEnglishWord(tokenText)
            let idx = tokens.count
            tokens.append(TokenInfo(range: r, text: tokenText, normalized: normalized))

            if let d = bestDistance(for: tokenText), d <= distanceThreshold {
                scored.append(ScoredRange(range: r, distance: d, token: tokenText, tokenIndex: idx))
            }
            return true
        }

        guard scored.isEmpty == false else { return [] }
        scored.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            // Prefer longer tokens when distance ties.
            if lhs.token.count != rhs.token.count { return lhs.token.count > rhs.token.count }
            return lhs.range.location < rhs.range.location
        }

        var picked: [NSRange] = []
        picked.reserveCapacity(maxHighlights * 2)

        for item in scored {
            // Expand to include a directly-adjacent negation token (e.g. "don't" + "mind")
            // without hardcoding any specific phrase patterns.
            if item.tokenIndex - 1 >= 0 {
                let prev = tokens[item.tokenIndex - 1]
                if isNegationToken(prev.text) {
                    picked.append(prev.range)
                }
            }
            picked.append(item.range)
            if picked.count >= maxHighlights * 2 { break }
        }

        // De-dupe while preserving order.
        var seenRanges: Set<String> = []
        picked = picked.filter { r in
            let key = "\(r.location):\(r.length)"
            if seenRanges.insert(key).inserted {
                return true
            }
            return false
        }

        // Ensure ranges are within bounds.
        return picked.filter { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= full.length }
    }

    private var englishStopwords: Set<String> {
        [
            "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "he",
            "her", "his", "i", "if", "in", "into", "is", "it", "its", "me", "my", "no", "not", "of", "on",
            "or", "our", "out", "she", "so", "that", "the", "their", "them", "then", "there", "they", "this",
            "to", "up", "us", "was", "we", "were", "what", "when", "where", "who", "will", "with", "you", "your"
        ]
    }

    private func normalizeEnglishWord(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.isEmpty == false else { return "" }

        // Trim leading/trailing punctuation.
        s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
        guard s.isEmpty == false else { return "" }

        // Strip possessive.
        if s.hasSuffix("'s") {
            s = String(s.dropLast(2))
        }
        return s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    }

    private func englishGlossKeywordCandidates(maxCount: Int) -> [String] {
        // Derive single-word keyword candidates from raw gloss text.
        // Includes parenthetical hints like "(old)" and basic morphology stems like "miss" from "missed".
        var out: [String] = []
        var seen: Set<String> = []

        func addWord(_ raw: String) {
            let w = normalizeEnglishWord(raw)
            guard w.isEmpty == false else { return }
            guard w.count >= 3 else { return }
            guard englishStopwords.contains(w) == false else { return }
            if seen.insert(w).inserted {
                out.append(w)
            }

            // Add a tiny set of stems (best-effort; no heavy lemmatizer here).
            if w.hasSuffix("ed"), w.count > 4 {
                let stem = String(w.dropLast(2))
                if stem.count >= 3, englishStopwords.contains(stem) == false, seen.insert(stem).inserted {
                    out.append(stem)
                }
            }
            if w.hasSuffix("s"), w.count > 3 {
                let stem = String(w.dropLast())
                if stem.count >= 3, englishStopwords.contains(stem) == false, seen.insert(stem).inserted {
                    out.append(stem)
                }
            }
        }

        func harvest(from text: String) {
            // Keep parenthetical content as additional candidates.
            // Example: "dear (old)" => add "dear" and "old".
            let separators = CharacterSet(charactersIn: ";,/\n")
            let parts = text
                .components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }

            for part in parts {
                // Add outside parentheses.
                let outside: String = {
                    if let idx = part.firstIndex(of: "(") {
                        return String(part[..<idx])
                    }
                    return part
                }()
                outside
                    .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
                    .forEach(addWord)

                // Add inside parentheses.
                if let open = part.firstIndex(of: "("), let close = part.firstIndex(of: ")"), open < close {
                    let inside = String(part[part.index(after: open)..<close])
                    inside
                        .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-")))
                        .forEach(addWord)
                }

                if out.count >= max(1, maxCount) { return }
            }
        }

        for detail in entryDetails {
            let senses = orderedSensesForDisplay(detail)
            for sense in senses {
                let english = sense.glosses.filter { $0.language == "eng" || $0.language.isEmpty }
                let source = english.isEmpty ? sense.glosses : english
                for g in source {
                    harvest(from: g.text)
                    if out.count >= max(1, maxCount) { return out }
                }
            }
        }

        return out
    }

    private func englishGlossPhraseCandidates() -> [String] {
        // Collect plausible English phrases from all senses.
        // We then try to match these phrases verbatim (case-insensitive) inside the translation.
        var out: [String] = []
        var seen: Set<String> = []

        for detail in entryDetails {
            let senses = orderedSensesForDisplay(detail)
            for sense in senses {
                let english = sense.glosses.filter { $0.language == "eng" || $0.language.isEmpty }
                let source = english.isEmpty ? sense.glosses : english
                for g in source {
                    let raw = g.text
                    for phrase in splitEnglishGlossPhrases(raw) {
                        let normalized = normalizeEnglishPhraseCandidate(phrase)
                        guard normalized.isEmpty == false else { continue }
                        let key = normalized.lowercased()
                        if seen.insert(key).inserted {
                            out.append(normalized)
                        }
                        if out.count >= 80 { break }
                    }
                    if out.count >= 80 { break }
                }
                if out.count >= 80 { break }
            }
            if out.count >= 80 { break }
        }

        // Prefer longer (more specific) phrases first.
        out.sort { a, b in
            let aw = a.split(whereSeparator: { $0 == " " || $0 == "-" }).count
            let bw = b.split(whereSeparator: { $0 == " " || $0 == "-" }).count
            if aw != bw { return aw > bw }
            if a.count != b.count { return a.count > b.count }
            return a < b
        }
        return out
    }

    private func splitEnglishGlossPhrases(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        // Split on common gloss separators.
        let separators = CharacterSet(charactersIn: ";,/\n")
        let parts = trimmed
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        // Also strip parenthetical notes but keep the main phrase.
        return parts.map { part in
            if let idx = part.firstIndex(of: "(") {
                return String(part[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return part
        }.filter { $0.isEmpty == false }
    }

    private func normalizeEnglishPhraseCandidate(_ phrase: String) -> String {
        var p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.isEmpty == false else { return "" }

        // Remove leading "to " to better match actual translation phrases.
        if p.lowercased().hasPrefix("to ") {
            p = String(p.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop surrounding quotes.
        if (p.hasPrefix("\"") && p.hasSuffix("\"")) || (p.hasPrefix("'") && p.hasSuffix("'")) {
            p = String(p.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Keep only phrases that contain at least one letter.
        if p.rangeOfCharacter(from: .letters) == nil {
            return ""
        }

        // Avoid extremely generic phrases.
        let lower = p.lowercased()
        let banned: Set<String> = ["thing", "person", "something", "someone", "to do", "do"]
        if banned.contains(lower) {
            return ""
        }

        return p
    }

    private func englishPhraseRegex(for phrase: String) -> NSRegularExpression? {
        let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false else { return nil }

        // Convert phrase into a word-boundary-aware regex, allowing flexible whitespace/hyphen.
        let words = cleaned
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })
            .map(String.init)
            .filter { $0.isEmpty == false }
        guard words.isEmpty == false else { return nil }

        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }
        let body = escaped.map { "\\b\($0)\\b" }.joined(separator: "[\\s\\-]+");

        do {
            return try NSRegularExpression(pattern: body, options: [.caseInsensitive])
        } catch {
            return nil
        }
    }

    private func highlightedJapaneseSentence(_ sentence: String) -> AttributedString {
        let s = sentence
        guard s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return AttributedString(sentence) }

        var terms: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
            if terms.contains(trimmed) == false {
                terms.append(trimmed)
            }
        }

        // Keep highlighting aligned with sentence lookup terms (and avoid component-term highlighting).
        let lookupAligned = sentenceLookupTerms(primaryTerms: [surface, kana].compactMap { $0 }, entryDetails: entryDetails)
        for term in lookupAligned { add(term) }
        // Lemma candidates can include component lemmas for compounds; filter those out.
        let partTerms: Set<String> = {
            var s: Set<String> = []
            for part in tokenParts {
                let surface = part.surface.trimmingCharacters(in: .whitespacesAndNewlines)
                if surface.isEmpty == false { s.insert(surface) }
                if let kana = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines), kana.isEmpty == false { s.insert(kana) }
            }
            return s
        }()
        for lemma in lemmaCandidates {
            let trimmed = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            guard partTerms.contains(trimmed) == false else { continue }
            add(trimmed)
        }

        guard terms.isEmpty == false else { return AttributedString(sentence) }

        let ns = s as NSString
        let mutable = NSMutableAttributedString(string: s)
        let baseColor = UIColor.secondaryLabel
        let highlightColor = UIColor.systemOrange

        // Dim the whole sentence so the highlight stands out.
        mutable.addAttribute(.foregroundColor, value: baseColor, range: NSRange(location: 0, length: ns.length))

        for term in terms {
            let needle = term as NSString
            guard needle.length > 0, needle.length <= ns.length else { continue }

            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: term, options: [], range: search)
                if found.location == NSNotFound || found.length == 0 { break }
                mutable.addAttribute(.foregroundColor, value: highlightColor, range: found)

                let nextLoc = NSMaxRange(found)
                if nextLoc >= ns.length { break }
                search = NSRange(location: nextLoc, length: ns.length - nextLoc)
            }
        }

        return AttributedString(mutable)
    }

    private func loadEntryDetails(for entries: [DictionaryEntry]) async -> [DictionaryEntryDetail] {
        let entryIDs = orderedEntryIDs(from: entries)
        guard entryIDs.isEmpty == false else { return [] }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try await DictionarySQLiteStore.shared.fetchEntryDetails(for: entryIDs)
            }.value
        } catch {
            return []
        }
    }

    private func orderedEntryIDs(from entries: [DictionaryEntry]) -> [Int64] {
        var seen: Set<Int64> = []
        var ordered: [Int64] = []
        ordered.reserveCapacity(entries.count)
        for entry in entries {
            let entryID = entry.entryID
            if seen.insert(entryID).inserted {
                ordered.append(entryID)
            }
        }
        return ordered
    }

    // MARK: Utilities
    private func preferredReading(from kanaVariants: [String]) -> String? {
        let cleaned = kanaVariants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard cleaned.isEmpty == false else { return nil }

        func isAllHiragana(_ text: String) -> Bool {
            guard text.isEmpty == false else { return false }
            return text.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
        }

        // Prefer a hiragana reading when available; otherwise fall back to the shortest.
        if let hira = cleaned.first(where: isAllHiragana) { return hira }
        return cleaned.min(by: { $0.count < $1.count })
    }

    private func glossParts(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let parts = trimmed
            .split(separator: ";", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        return parts.isEmpty ? [trimmed] : parts
    }

    private func containsKanji(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                continue
            }
        }
        return false
    }

    private func kanaFoldToHiragana(_ value: String) -> String {
        value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
    }

    private func firstGloss(for gloss: String) -> String {
        gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? gloss
    }

    private func isSaved(surface: String, kana: String?) -> Bool {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return false }
        return store.words.contains { $0.surface == s && $0.kana == normalizedKana }
    }

    private func savedWordID(surface: String, kana: String?) -> UUID? {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return nil }
        return store.words.first(where: { $0.surface == s && $0.kana == normalizedKana })?.id
    }

    private func savedWordCreatedAt(surface: String, kana: String?) -> Date? {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        guard s.isEmpty == false else { return nil }
        return store.words.first(where: { $0.surface == s && $0.kana == normalizedKana })?.createdAt
    }

    /// Ensures the word is saved, returning its Word.ID if possible.
    private func ensureSavedWordID(surface: String, kana: String?, meaning: String) -> UUID? {
        if let id = savedWordID(surface: surface, kana: kana) {
            return id
        }

        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false, m.isEmpty == false else { return nil }

        store.add(surface: s, kana: normalizedKana, meaning: m)
        return savedWordID(surface: s, kana: normalizedKana)
    }

    private func toggleSaved(surface: String, kana: String?, meaning: String) {
        let s = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = (k?.isEmpty == false) ? k : nil
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.isEmpty == false, m.isEmpty == false else { return }

        let matchingIDs = Set(
            store.words
                .filter { $0.surface == s && $0.kana == normalizedKana }
                .map(\.id)
        )

        if matchingIDs.isEmpty {
            store.add(surface: s, kana: normalizedKana, meaning: m)
        } else {
            store.delete(ids: matchingIDs)
        }
    }

    // MARK: Layout Debug Colors
    private enum LayoutDebugColor {
        // Search tip: use these color words to find the associated UI layer.
        static let DBG_GRAY__List = Color.gray.opacity(0.06)

        static let DBG_CYAN__SectionHeader = Color.cyan.opacity(0.12)

        static let DBG_TEAL__HeaderNoteRow = Color.teal.opacity(0.12)
        static let DBG_MINT__HeaderTitleRow = Color.mint.opacity(0.12)

        static let DBG_YELLOW__LoadingRow = Color.yellow.opacity(0.14)
        static let DBG_RED__ErrorRow = Color.red.opacity(0.12)
        static let DBG_ORANGE__EmptyRow = Color.orange.opacity(0.12)

        static let DBG_BLUE__DefinitionRow = Color.blue.opacity(0.10)
        static let DBG_PURPLE__DefinitionRowHeader = Color.purple.opacity(0.12)
        static let DBG_ORANGE__DefinitionGloss = Color.orange.opacity(0.10)
        static let DBG_GRAY__DefinitionMore = Color.gray.opacity(0.10)

        static let DBG_GREEN__FullEntryRow = Color.green.opacity(0.10)
        static let DBG_INDIGO__EntryHeader = Color.indigo.opacity(0.12)
        static let DBG_PINK__SenseRow = Color.pink.opacity(0.10)
        static let DBG_GRAY__SenseMeta = Color.gray.opacity(0.10)
        static let DBG_YELLOW__SenseGloss = Color.yellow.opacity(0.10)

        static let DBG_RED__SQLRow = Color.red.opacity(0.10)
    }

    private struct DebugBackground: ViewModifier {
        let enabled: Bool
        let color: Color

        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content.background(color)
            } else {
                content
            }
        }
    }

    private struct DebugListRowBackground: ViewModifier {
        let enabled: Bool
        let color: Color

        @ViewBuilder
        func body(content: Content) -> some View {
            if enabled {
                content.listRowBackground(color)
            } else {
                content
            }
        }
    }

    private func dbgBG(_ color: Color) -> some ViewModifier {
        DebugBackground(enabled: layoutDebugColorsEnabled, color: color)
    }

    private func dbgRowBG(_ color: Color) -> some ViewModifier {
        DebugListRowBackground(enabled: layoutDebugColorsEnabled, color: color)
    }
}

private struct WordListAssignmentSheet: View {
    @EnvironmentObject private var store: WordsStore
    @Environment(\.dismiss) private var dismiss

    let wordID: Word.ID
    let title: String

    @State private var selectedListIDs: Set<UUID> = []
    @State private var newListName: String = ""

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

private struct ComponentPreviewSheet: View {
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

