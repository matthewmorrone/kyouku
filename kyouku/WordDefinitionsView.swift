import SwiftUI

struct WordDefinitionsView: View {
    @EnvironmentObject var store: WordsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var notesStore: NotesStore

    let surface: String
    let kana: String?
    let sourceNoteID: UUID?

    @State private var entries: [DictionaryEntry] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

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

    var body: some View {
        List {
            Section {
                if let noteID = sourceNoteID, let note = notesStore.notes.first(where: { $0.id == noteID }) {
                    HStack(spacing: 10) {
                        Image(systemName: "book")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((note.title?.isEmpty == false ? note.title : nil) ?? "Untitled")
                                .font(.subheadline.weight(.semibold))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            router.noteToOpen = note
                            router.selectedTab = .paste
                        } label: {
                            Image(systemName: "arrowshape.turn.up.right")
                                .font(.title2)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text(titleText)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage, errorMessage.isEmpty == false {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                } else if entries.isEmpty {
                    Text("No definitions found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(definitionRows) { row in
                        definitionRowView(row)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var titleText: String {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        if primary.isEmpty == false { return primary }
        return kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if containsKanji(row.headword) {
                    Text(normalizedReading ?? "(no reading)")
                        .font(.headline)
                } else {
                    // Kana headword: do not show kanji spellings.
                    Text(row.headword)
                        .font(.headline)
                }

                Spacer(minLength: 0)

                Button {
                    // Store meaning as the first page (best available summary).
                    let meaning = row.pages.first?.gloss ?? ""
                    toggleSaved(surface: row.headword, kana: normalizedReading, meaning: meaning)
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(isSaved ? .accentColor : .secondary)
                .accessibilityLabel(isSaved ? "Saved" : "Save")
            }

            if row.pages.count <= 1, let page = row.pages.first {
                Text(page.gloss)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                TabView {
                    ForEach(row.pages) { page in
                        Text(page.gloss)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 64)
            }
        }
        .padding(.vertical, 6)
    }

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
            return
        }

        isLoading = true
        errorMessage = nil

        var merged: [DictionaryEntry] = []
        var seen: Set<String> = []

        do {
            for term in terms {
                let rows = try await DictionarySQLiteStore.shared.lookup(term: term, limit: 100)
                for row in rows {
                    if seen.insert(row.id).inserted {
                        merged.append(row)
                    }
                }
            }
            entries = merged
            isLoading = false
        } catch {
            entries = []
            isLoading = false
            errorMessage = String(describing: error)
        }
    }

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
}

