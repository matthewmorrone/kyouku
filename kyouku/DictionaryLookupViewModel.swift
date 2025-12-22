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

    func load(term: String) async {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        query = t

        guard !t.isEmpty else {
            results = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let rows = try await DictionarySQLiteStore.shared.lookup(term: t, limit: 50)
            results = rows
        } catch {
            results = []
            errorMessage = String(describing: error)
        }

        isLoading = false
    }
}


