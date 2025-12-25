//
//  DictionaryLookupViewModel.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//


import SwiftUI
import Combine

@MainActor
final class DictionaryLookupViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [DictionaryEntry] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    func load(term: String, fallbackTerms: [String] = []) async {
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
                let rows = try await DictionarySQLiteStore.shared.lookup(term: candidate, limit: 50)
                if rows.isEmpty == false {
                    results = rows
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


