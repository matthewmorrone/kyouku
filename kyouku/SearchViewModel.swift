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

    enum JLPTFilter: String, CaseIterable, Identifiable {
        case any
        case n1
        case n2
        case n3
        case n4
        case n5

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: return "Any"
            case .n1: return "N1"
            case .n2: return "N2"
            case .n3: return "N3"
            case .n4: return "N4"
            case .n5: return "N5"
            }
        }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case relevance
        case commonFirst
        case alphabetical

        var id: String { rawValue }

        var title: String {
            switch self {
            case .relevance: return "Relevance"
            case .commonFirst: return "Common-first"
            case .alphabetical: return "Alphabetical"
            }
        }
    }

    struct ResultControls: Equatable {
        var commonWordsOnly: Bool
        var selectedPartsOfSpeech: Set<DictionaryPartOfSpeech>
        var selectedJLPT: JLPTFilter
        var sortMode: SortMode

        static let `default` = ResultControls(
            commonWordsOnly: false,
            selectedPartsOfSpeech: [],
            selectedJLPT: .any,
            sortMode: .relevance
        )
    }

    @Published var query: String = ""
    @Published var lookupMode: DictionarySearchMode = .japanese
    @Published var displayMode: DisplayMode = .japanese
    @Published var commonWordsOnly: Bool = false
    @Published var selectedPartsOfSpeech: Set<DictionaryPartOfSpeech> = []
    @Published var selectedJLPT: JLPTFilter = .any
    @Published var sortMode: SortMode = .relevance

    @Published private(set) var bestMatches: [DictionaryResultRow] = []
    @Published private(set) var additionalMatches: [DictionaryResultRow] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private let lookup = DictionaryLookupViewModel()
    private var cancellables: Set<AnyCancellable> = []
    private var activeSearchTask: Task<Void, Never>?
    private var mergedRowsCache: [DictionaryResultRow] = []

    init() {
        Publishers.CombineLatest($query, $lookupMode)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] query, mode in
                guard let self else { return }
                self.search(query: query, mode: mode)
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4($commonWordsOnly, $selectedPartsOfSpeech, $selectedJLPT, $sortMode)
            .sink { [weak self] _, _, _, _ in
                self?.applyResultControls()
            }
            .store(in: &cancellables)
    }

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveSearch: Bool {
        trimmedQuery.isEmpty == false
    }

    var availablePartsOfSpeech: [DictionaryPartOfSpeech] {
        var seen: Set<DictionaryPartOfSpeech> = []
        var ordered: [DictionaryPartOfSpeech] = []
        for row in mergedRowsCache {
            for pos in row.partsOfSpeech where seen.insert(pos).inserted {
                ordered.append(pos)
            }
        }
        return ordered
    }

    var hasAvailableJLPTData: Bool {
        mergedRowsCache.contains(where: { $0.jlptLevel != nil })
    }

    var hasActiveControls: Bool {
        currentControls != .default
    }

    func togglePartOfSpeech(_ value: DictionaryPartOfSpeech) {
        if selectedPartsOfSpeech.contains(value) {
            selectedPartsOfSpeech.remove(value)
        } else {
            selectedPartsOfSpeech.insert(value)
        }
    }

    func resetFilters() {
        commonWordsOnly = false
        selectedPartsOfSpeech = []
        selectedJLPT = .any
        sortMode = .relevance
    }

    func clearSearch() {
        query = ""
        mergedRowsCache = []
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

            let entryIDs = Array(Set(self.lookup.results.map(\.entryID)))
            let details = (try? await DictionarySQLiteStore.shared.fetchEntryDetails(for: entryIDs)) ?? []
            let detailsByEntryID = Dictionary(uniqueKeysWithValues: details.map { ($0.entryID, $0) })

            await MainActor.run {
                self.mergedRowsCache = Self.mergeLookupResults(
                    self.lookup.results,
                    searchTerm: trimmed,
                    detailsByEntryID: detailsByEntryID
                )
                self.applyResultControls()
                self.errorMessage = self.lookup.errorMessage
                self.isLoading = self.lookup.isLoading
            }
        }
    }

    private var currentControls: ResultControls {
        ResultControls(
            commonWordsOnly: commonWordsOnly,
            selectedPartsOfSpeech: selectedPartsOfSpeech,
            selectedJLPT: selectedJLPT,
            sortMode: sortMode
        )
    }

    private func applyResultControls() {
        let visible = Self.applyFiltersAndSort(to: mergedRowsCache, controls: currentControls)
        let grouped = Self.groupedRows(from: visible)
        bestMatches = grouped.best
        additionalMatches = grouped.additional
    }

    static func applyFiltersAndSort(to rows: [DictionaryResultRow], controls: ResultControls) -> [DictionaryResultRow] {
        let filtered = rows.filter { row in
            if controls.commonWordsOnly, row.isCommon == false {
                return false
            }

            if controls.selectedPartsOfSpeech.isEmpty == false,
               row.partsOfSpeech.isDisjoint(with: controls.selectedPartsOfSpeech) {
                return false
            }

            if controls.selectedJLPT != .any {
                guard let rowJLPT = row.jlptLevel,
                      rowJLPT.matches(filter: controls.selectedJLPT) else {
                    return false
                }
            }

            return true
        }

        switch controls.sortMode {
        case .relevance:
            return filtered
        case .commonFirst:
            return filtered
                .enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.isCommon != rhs.element.isCommon {
                        return lhs.element.isCommon && rhs.element.isCommon == false
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        case .alphabetical:
            return filtered
                .enumerated()
                .sorted { lhs, rhs in
                    let leftSurface = lhs.element.surface.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    let rightSurface = rhs.element.surface.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    let surfaceCompare = leftSurface.localizedCompare(rightSurface)
                    if surfaceCompare != .orderedSame {
                        return surfaceCompare == .orderedAscending
                    }

                    let leftKana = (lhs.element.kana ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    let rightKana = (rhs.element.kana ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    let kanaCompare = leftKana.localizedCompare(rightKana)
                    if kanaCompare != .orderedSame {
                        return kanaCompare == .orderedAscending
                    }

                    return lhs.offset < rhs.offset
                }
                .map(\.element)
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

    private static func mergeLookupResults(
        _ entries: [DictionaryEntry],
        searchTerm: String,
        detailsByEntryID: [Int64: DictionaryEntryDetail]
    ) -> [DictionaryResultRow] {
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
            buckets[key]?.build(
                firstGlossFor: firstGloss(for:),
                detailForEntryID: { entryID in detailsByEntryID[entryID] }
            )
        }
    }
}
