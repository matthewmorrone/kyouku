import SwiftUI

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

    @State private var exampleSentences: [ExampleSentence] = []
    @State private var isLoadingExampleSentences: Bool = false
    @State private var showAllExampleSentences: Bool = false

    @State private var detectedGrammar: [DetectedGrammarPattern] = []
    @State private var similarWords: [String] = []

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
                Text(titleText)
                    .font(.title2.weight(.semibold))
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // .modifier(dbgBG(LayoutDebugColor.DBG_MINT__HeaderTitleRow))
                    // .modifier(dbgRowBG(LayoutDebugColor.DBG_MINT__HeaderTitleRow))
            }
            // .modifier(dbgRowBG(LayoutDebugColor.DBG_CYAN__SectionHeader))

            if tokenParts.count > 1 {
                Section("Parts") {
                    ForEach(tokenParts) { part in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(part.surface)
                                .font(.body.weight(.semibold))
                            if let kana = part.kana?.trimmingCharacters(in: .whitespacesAndNewlines), kana.isEmpty == false, kana != part.surface {
                                Text("(\(kana))")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .textSelection(.enabled)
                    }
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
        .task {
            await load()
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
    }

    // MARK: Header
    private var titleText: String {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if primary.isEmpty == false { return primary }
        return kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Definitions
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

        guard relevant.isEmpty == false else { return [] }

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
            for (idx, entry) in relevant.enumerated() {
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
            let pages = pagesForEntries(relevant)
            guard pages.isEmpty == false else { return [] }
            return [DefinitionRow(headword: headword, reading: headword, pages: pages)]
        }
    }

    private func pagesForEntries(_ entries: [DictionaryEntry]) -> [DefinitionPage] {
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
    private func load() async {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
        var terms: [String] = []
        for t in [primary, secondary].compactMap({ $0 }) {
            guard t.isEmpty == false else { continue }
            if terms.contains(t) == false { terms.append(t) }
        }

        for lemma in lemmaCandidates {
            let trimmed = lemma.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if terms.contains(trimmed) == false { terms.append(trimmed) }
        }

        guard terms.isEmpty == false else {
            entries = []
            entryDetails = []
            return
        }

        isLoading = true
        errorMessage = nil
        entryDetails = []
        exampleSentences = []
        showAllExampleSentences = false
        isLoadingExampleSentences = true

        var merged: [DictionaryEntry] = []
        var seen: Set<String> = []

        do {
            for term in terms {
                let keys = DictionaryKeyPolicy.keys(forDisplayKey: term)
                guard keys.lookupKey.isEmpty == false else { continue }
                let rows = try await Task.detached(priority: .userInitiated) {
                    try await DictionarySQLiteStore.shared.lookup(term: keys.lookupKey, limit: 100)
                }.value
                for row in rows {
                    if seen.insert(row.id).inserted {
                        merged.append(row)
                    }
                }
            }
            entries = merged
            let details = await loadEntryDetails(for: merged)
            if coarseTokenPOS() != nil {
                entryDetails = details.sorted { lhs, rhs in
                    let lhsTier = lhs.senses.contains(where: senseMatchesTokenPOS) ? 0 : 1
                    let rhsTier = rhs.senses.contains(where: senseMatchesTokenPOS) ? 0 : 1
                    if lhsTier != rhsTier { return lhsTier < rhsTier }
                    if lhs.isCommon != rhs.isCommon { return lhs.isCommon && rhs.isCommon == false }
                    return lhs.entryID < rhs.entryID
                }
            } else {
                entryDetails = details
            }

            let sentenceTerms = sentenceLookupTerms(primaryTerms: terms, entryDetails: details)
            do {
                let sentences = try await Task.detached(priority: .utility) {
                    try await DictionarySQLiteStore.shared.fetchExampleSentences(containing: sentenceTerms, limit: 8)
                }.value
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
            debugSQL = await Task.detached(priority: .utility) {
                await DictionarySQLiteStore.shared.debugLastQueryDescription()
            }.value
        } catch {
            entries = []
            entryDetails = []
            exampleSentences = []
            isLoadingExampleSentences = false
            isLoading = false
            errorMessage = String(describing: error)
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
        var out: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return }
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
            Text(highlightedJapaneseSentence(sentence.jpText))
                .fixedSize(horizontal: false, vertical: true)
            Text(sentence.enText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
        .padding(.vertical, 4)
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

        add(surface)
        add(kana)
        for lemma in lemmaCandidates { add(lemma) }
        if let first = entryDetails.first {
            add(primaryHeadword(for: first))
            add(first.kanaForms.first?.text)
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

