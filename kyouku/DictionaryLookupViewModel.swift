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

    func load(term: String, fallbackTerms: [String] = [], englishFirst: Bool = false) async {
        await ivtimeAsync("DictionaryLookup.load") {
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

            ivlog("DictionaryLookup.candidates count=\(candidates.count) primaryLen=\(primary.count)")

            guard candidates.isEmpty == false else {
                results = []
                errorMessage = nil
                return
            }

            isLoading = true
            errorMessage = nil

            let mode: DictionarySearchMode = englishFirst ? .englishFirst : .auto

            for (idx, candidate) in candidates.enumerated() {
                ivlog("DictionaryLookup.attempt \(idx + 1)/\(candidates.count) termLen=\(candidate.count)")
                do {
                    // IMPORTANT: keep SQLite work off the MainActor so UI state updates
                    // (highlight/ruby overlay layout) can render immediately.
                    let (rows, ranOnMainThread): ([DictionaryEntry], Bool) = try await ivtimeAsync("DictionaryLookup.sqliteLookup") {
                        try await Task.detached(priority: .userInitiated) {
                            let ranOnMain = pthread_main_np() != 0
                            let rows = try await DictionarySQLiteStore.shared.lookup(term: candidate, limit: 50, mode: mode)
                            return (rows, ranOnMain)
                        }.value
                    }
                    ivlog("DictionaryLookup.sqliteLookup.thread main=\(ranOnMainThread)")
                    if rows.isEmpty == false {
                        results = rows
                        isLoading = false
                        errorMessage = nil
                        ivlog("DictionaryLookup.hit attempt=\(idx + 1) rows=\(rows.count)")
                        return
                    }
                } catch {
                    results = []
                    errorMessage = String(describing: error)
                    isLoading = false
                    ivlog("DictionaryLookup.error attempt=\(idx + 1) err=\(String(describing: error))")
                    return
                }
            }

            results = []
            isLoading = false
            ivlog("DictionaryLookup.miss attempts=\(candidates.count)")
        }
    }
}


