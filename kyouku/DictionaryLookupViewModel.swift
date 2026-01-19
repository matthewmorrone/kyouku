//
//  DictionaryLookupViewModel.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//


import SwiftUI
import Combine
import Darwin

@MainActor
final class DictionaryLookupViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [DictionaryEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    func load(term: String, fallbackTerms: [String] = [], mode: DictionarySearchMode = .japanese) async {
        let primary = term.trimmingCharacters(in: .whitespacesAndNewlines)
        query = primary

        let normalizedFallbacks = fallbackTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        var candidates: [String] = []
        for candidate in [primary] + normalizedFallbacks {
            guard candidate.isEmpty == false else { continue }
            if candidates.contains(candidate) == false {
                candidates.append(candidate)
            }
        }

        guard candidates.isEmpty == false else {
            results = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        for candidate in candidates {
            do {
                // Keep SQLite work off the MainActor so highlight/ruby overlays can render immediately.
                let rows: [DictionaryEntry] = try await Task.detached(priority: .userInitiated) {
                    try await DictionarySQLiteStore.shared.lookup(term: candidate, limit: 50, mode: mode)
                }.value

                if rows.isEmpty == false {
                    let rankedRows = rankResults(rows, for: candidate, mode: mode)
                    results = rankedRows
                    isLoading = false
                    errorMessage = nil
                    return
                }
            } catch {
                results = []
                errorMessage = String(describing: error)
                isLoading = false
                return
            }
        }

        results = []
        isLoading = false
    }
}

private extension DictionaryLookupViewModel {
    func rankResults(_ rows: [DictionaryEntry], for term: String, mode: DictionarySearchMode) -> [DictionaryEntry] {
        guard mode == .english else { return rows }
        let key = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard key.isEmpty == false else { return rows }
        return rows.sorted { lhs, rhs in
            englishScore(for: lhs, query: key) < englishScore(for: rhs, query: key)
        }
    }

    func englishScore(for entry: DictionaryEntry, query: String) -> (Int, Int, Int, Int, Int, Int64) {
        let components = glossComponents(from: entry.gloss)
        var bestBucket = 4
        var bestIndex = components.count
        var bestLengthDelta = Int.max
        var bestContainsPenalty = 1

        for (idx, component) in components.enumerated() {
            let bucket: Int
            if component == query {
                bucket = 0
            } else if component.hasPrefix(query) {
                bucket = 1
            } else if component.contains(query) {
                bucket = 2
            } else {
                bucket = 3
            }

            let lengthDelta = abs(component.count - query.count)
            let containsPenalty = component.contains(" ") ? 1 : 0
            let candidate = (bucket, idx, lengthDelta, containsPenalty)
            let best = (bestBucket, bestIndex, bestLengthDelta, bestContainsPenalty)
            if candidate.0 < best.0
                || (candidate.0 == best.0 && candidate.1 < best.1)
                || (candidate.0 == best.0 && candidate.1 == best.1 && candidate.2 < best.2)
                || (candidate.0 == best.0 && candidate.1 == best.1 && candidate.2 == best.2 && candidate.3 < best.3) {
                bestBucket = candidate.0
                bestIndex = candidate.1
                bestLengthDelta = candidate.2
                bestContainsPenalty = candidate.3
            }
        }

        let commonPenalty = entry.isCommon ? 0 : 1
        // Lower tuple sorts first. Use entryID as final tie-breaker for determinism.
        return (bestBucket, bestIndex, bestLengthDelta, bestContainsPenalty, commonPenalty, Int64(entry.entryID))
    }

    func glossComponents(from gloss: String) -> [String] {
        let separators = CharacterSet(charactersIn: ";,/")
        return gloss
            .lowercased()
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }
}


