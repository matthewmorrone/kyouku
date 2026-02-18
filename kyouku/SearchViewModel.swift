import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    enum DisplayMode: String, CaseIterable {
        case japanese
        case english

        var title: String {
            switch self {
            case .japanese: return "JP"
            case .english: return "EN"
            }
        }
    }

    @Published var query: String = ""
    @Published var lookupMode: DictionarySearchMode = .japanese
    @Published var displayMode: DisplayMode = .japanese

    @Published private(set) var bestMatches: [DictionaryResultRow] = []
    @Published private(set) var additionalMatches: [DictionaryResultRow] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private let lookup = DictionaryLookupViewModel()
    private var cancellables: Set<AnyCancellable> = []
    private var activeSearchTask: Task<Void, Never>?

    init() {
        Publishers.CombineLatest($query, $lookupMode)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] query, mode in
                guard let self else { return }
                self.search(query: query, mode: mode)
            }
            .store(in: &cancellables)
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveSearch: Bool {
        trimmedQuery.isEmpty == false
    }

    func clearSearch() {
        query = ""
        bestMatches = []
        additionalMatches = []
        errorMessage = nil
        isLoading = false
        activeSearchTask?.cancel()
        activeSearchTask = nil
    }

    private func search(query: String, mode: DictionarySearchMode) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchTask?.cancel()

        guard trimmed.isEmpty == false else {
            bestMatches = []
            additionalMatches = []
            errorMessage = nil
            isLoading = false
            return
        }

        activeSearchTask = Task { [weak self] in
            guard let self else { return }

            await MainActor.run {
                self.isLoading = true
                self.errorMessage = nil
            }

            await self.lookup.load(term: trimmed, mode: mode)
            if Task.isCancelled { return }

            if self.lookup.results.isEmpty {
                let fallback: DictionarySearchMode = (mode == .english) ? .japanese : .english
                await self.lookup.load(term: trimmed, mode: fallback)
                if Task.isCancelled { return }
            }

            await MainActor.run {
                let merged = Self.mergeLookupResults(self.lookup.results, searchTerm: trimmed)
                let grouped = Self.groupedRows(from: merged)
                self.bestMatches = grouped.best
                self.additionalMatches = grouped.additional
                self.errorMessage = self.lookup.errorMessage
                self.isLoading = self.lookup.isLoading
            }
        }
    }

    private static func groupedRows(from rows: [DictionaryResultRow]) -> (best: [DictionaryResultRow], additional: [DictionaryResultRow]) {
        guard rows.isEmpty == false else { return ([], []) }

        let commons = rows.filter { $0.isCommon }
        if commons.isEmpty == false {
            let commonIDs = Set(commons.map(\.id))
            let additional = rows.filter { commonIDs.contains($0.id) == false }
            return (commons, additional)
        }

        let split = min(8, rows.count)
        let best = Array(rows.prefix(split))
        let additional = Array(rows.dropFirst(split))
        return (best, additional)
    }

    private static func mergeLookupResults(_ entries: [DictionaryEntry], searchTerm: String) -> [DictionaryResultRow] {
        guard entries.isEmpty == false else { return [] }

        func displaySurface(for entry: DictionaryEntry) -> String {
            if entry.kanji.isEmpty {
                if let kana = entry.kana, kana.isEmpty == false {
                    return kana
                }
                return searchTerm
            }
            return entry.kanji
        }

        func firstGloss(for entry: DictionaryEntry) -> String {
            entry.gloss
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? entry.gloss
        }

        func kanaFoldToHiragana(_ value: String) -> String {
            value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
        }

        var buckets: [String: DictionaryResultRow.Builder] = [:]
        var orderedKeys: [String] = []

        for entry in entries {
            let surface = displaySurface(for: entry)
            let rawKana = entry.kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let kanaKey = rawKana.isEmpty ? "" : kanaFoldToHiragana(rawKana)
            let key = "\(surface)|\(kanaKey)"

            if var builder = buckets[key] {
                builder.entries.append(entry)
                buckets[key] = builder
            } else {
                buckets[key] = DictionaryResultRow.Builder(surface: surface, kanaKey: kanaKey, entries: [entry])
                orderedKeys.append(key)
            }
        }

        return orderedKeys.compactMap { key in
            buckets[key]?.build(firstGlossFor: firstGloss(for:))
        }
    }
}
