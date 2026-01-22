import SwiftUI

struct WordDefinitionsView: View {
    @EnvironmentObject var store: WordsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var notesStore: NotesStore

    let surface: String
    let kana: String?
    let sourceNoteID: UUID?

    @State private var entries: [DictionaryEntry] = []
    @State private var entryDetails: [DictionaryEntryDetail] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var debugSQL: String = ""

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
        .task { await load() }
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
            for gloss in glossParts(entry.gloss) {
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

        let primaryGloss = row.pages.first?.gloss ?? ""
        let extraCount = max(0, row.pages.count - 1)

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
                }

                Spacer(minLength: 0)

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
            }
            // .modifier(dbgBG(LayoutDebugColor.DBG_PURPLE__DefinitionRowHeader))

            if primaryGloss.isEmpty == false {
                Text(primaryGloss)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    // .modifier(dbgBG(LayoutDebugColor.DBG_ORANGE__DefinitionGloss))
            }

            if extraCount > 0 {
                Text("+\(extraCount) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

                ForEach(Array(detail.senses.enumerated()), id: \.element.id) { index, sense in
                    senseView(sense, index: index + 1)
                    if index < detail.senses.count - 1 {
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

    private func senseView(_ sense: DictionaryEntrySense, index: Int) -> some View {
        let glossLine = joinedGlossLine(for: sense)
        let noteLine = formattedSenseNotes(for: sense)

        return VStack(alignment: .leading, spacing: 6) {
            if let glossLine {
                Text(numberedGlossText(index: index, gloss: glossLine, notes: noteLine))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(index).")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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

        guard terms.isEmpty == false else {
            entries = []
            entryDetails = []
            return
        }

        isLoading = true
        errorMessage = nil
        entryDetails = []

        var merged: [DictionaryEntry] = []
        var seen: Set<String> = []

        do {
            for term in terms {
                let rows = try await Task.detached(priority: .userInitiated) {
                    try await DictionarySQLiteStore.shared.lookup(term: term, limit: 100)
                }.value
                for row in rows {
                    if seen.insert(row.id).inserted {
                        merged.append(row)
                    }
                }
            }
            entries = merged
            entryDetails = await loadEntryDetails(for: merged)
            isLoading = false
            debugSQL = await Task.detached(priority: .utility) {
                await DictionarySQLiteStore.shared.debugLastQueryDescription()
            }.value
        } catch {
            entries = []
            entryDetails = []
            isLoading = false
            errorMessage = String(describing: error)
        }
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

