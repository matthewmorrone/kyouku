import SwiftUI

struct WordDefinitionsView: View {
    @EnvironmentObject var store: WordsStore

    let surface: String
    let kana: String?

    @State private var entries: [DictionaryEntry] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        List {
            Section {
                Text(titleText)
                    .font(.largeTitle.weight(.semibold))
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    ForEach(entries) { entry in
                        definitionRow(entry)
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

    private func definitionRow(_ entry: DictionaryEntry) -> some View {
        let reading = (entry.kana ?? entry.kanji).trimmingCharacters(in: .whitespacesAndNewlines)
        let savedSurface = displaySurface(for: entry)
        let isSaved = isSaved(surface: savedSurface, kana: entry.kana)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reading.isEmpty ? "(no reading)" : reading)
                        .font(.headline)

                    if savedSurface != titleText, savedSurface.isEmpty == false {
                        Text(savedSurface)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    toggleSaved(surface: savedSurface, kana: entry.kana, meaning: firstGloss(for: entry))
                } label: {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.bordered)
                .tint(isSaved ? .accentColor : .secondary)
                .accessibilityLabel(isSaved ? "Saved" : "Save")
            }

            if entry.gloss.isEmpty == false {
                Text(entry.gloss)
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

    private func displaySurface(for entry: DictionaryEntry) -> String {
        if entry.kanji.isEmpty {
            if let kana = entry.kana, kana.isEmpty == false {
                return kana
            }
            return surface
        }
        return entry.kanji
    }

    private func firstGloss(for entry: DictionaryEntry) -> String {
        entry.gloss.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? entry.gloss
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
