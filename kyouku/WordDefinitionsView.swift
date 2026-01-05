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

    private struct DefinitionGroup: Identifiable, Hashable {
        let entryID: Int64
        let gloss: String
        let isCommon: Bool
        /// Unique spellings (kanji + kana variants) for this entry.
        let spellings: [String]
        /// All kana variants observed for this entry.
        let kanaVariants: [String]

        var id: Int64 { entryID }
    }

    var body: some View {
        List {
            Section {
                Text(titleText)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let noteID = sourceNoteID, let note = notesStore.notes.first(where: { $0.id == noteID }) {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "book")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((note.title?.isEmpty == false ? note.title : nil) ?? "Untitled")
                                .font(.subheadline.weight(.semibold))
                            Text("From note")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") {
                            router.noteToOpen = note
                            router.selectedTab = .paste
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let errorMessage, errorMessage.isEmpty == false {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
            } else if entries.isEmpty {
                Section {
                    Text("No definitions found.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(groupedDefinitions) { group in
                        definitionRow(group)
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

    private var groupedDefinitions: [DefinitionGroup] {
        // Keep first-seen ordering stable.
        var order: [Int64] = []
        var buckets: [Int64: [DictionaryEntry]] = [:]
        for entry in entries {
            if buckets[entry.entryID] == nil {
                order.append(entry.entryID)
                buckets[entry.entryID] = []
            }
            buckets[entry.entryID, default: []].append(entry)
        }

        let preferred = titleText.trimmingCharacters(in: .whitespacesAndNewlines)

        return order.compactMap { entryID in
            guard let groupEntries = buckets[entryID], let first = groupEntries.first else { return nil }

            var spellings: [String] = []
            var seenSpellings: Set<String> = []
            var kanaVariants: [String] = []
            var seenKana: Set<String> = []

            func addSpelling(_ s: String) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { return }
                if seenSpellings.insert(trimmed).inserted {
                    spellings.append(trimmed)
                }
            }
            func addKana(_ s: String) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else { return }
                if seenKana.insert(trimmed).inserted {
                    kanaVariants.append(trimmed)
                }
            }

            // Prefer showing the currently-viewed spelling first, if present.
            if preferred.isEmpty == false {
                addSpelling(preferred)
            }

            for e in groupEntries {
                addSpelling(e.kanji)
                if let k = e.kana { addSpelling(k) }
                if let k = e.kana { addKana(k) }
            }

            return DefinitionGroup(
                entryID: entryID,
                gloss: first.gloss,
                isCommon: first.isCommon,
                spellings: spellings,
                kanaVariants: kanaVariants
            )
        }
    }

    private func definitionRow(_ group: DefinitionGroup) -> some View {
        let preferredSurface = titleText
        let primarySurface = (group.spellings.first ?? preferredSurface).trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = preferredReading(from: group.kanaVariants)
        let isSaved = isSaved(surface: primarySurface, kana: reading)
        let otherSpellings = group.spellings
            .filter { $0 != primarySurface }
            .filter { $0.isEmpty == false }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    if let reading, reading.isEmpty == false {
                        Text(reading)
                            .font(.headline)

                        if primarySurface != reading, primarySurface.isEmpty == false {
                            Text(primarySurface)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("(no reading)")
                            .font(.headline)

                        if primarySurface.isEmpty == false {
                            Text(primarySurface)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button {
                    toggleSaved(surface: primarySurface, kana: reading, meaning: firstGloss(for: group.gloss))
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(isSaved ? .accentColor : .secondary)
                .accessibilityLabel(isSaved ? "Saved" : "Save")
            }

            if otherSpellings.isEmpty == false {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Other spellings")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(otherSpellings.enumerated()), id: \.element) { idx, spelling in
                        if idx > 0 {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        NavigationLink {
                            WordDefinitionsView(surface: spelling, kana: nil, sourceNoteID: sourceNoteID)
                        } label: {
                            Text(spelling)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if group.gloss.isEmpty == false {
                Text(group.gloss)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

