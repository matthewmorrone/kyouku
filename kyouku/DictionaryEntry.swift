//
//  DictionaryEntry.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation

/// Dictionary lookup result.
///
/// - Note: `kana` is the authoritative kana reading supplied by the dictionary
///   database. It reflects the canonical reading of the lexical entry but may
///   differ from how a word appears in running user text.
struct DictionaryEntry: Identifiable, Hashable {
    let entryID: Int64
    let kanji: String
    let kana: String?
    let gloss: String
    let isCommon: Bool
    private let stableIdentifier: String

    nonisolated init(entryID: Int64, kanji: String, kana: String?, gloss: String, isCommon: Bool) {
        self.entryID = entryID
        self.kanji = kanji
        self.kana = kana
        self.gloss = gloss
        self.isCommon = isCommon
        let kanaComponent = kana?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.stableIdentifier = "\(entryID)#\(kanaComponent)"
    }

    var id: String { stableIdentifier }
}

actor DictionaryEntryDetailsCache {
    static let shared = DictionaryEntryDetailsCache()

    private var detailsByEntryID: [Int64: DictionaryEntryDetail] = [:]

    func details(for entryIDs: [Int64]) async throws -> [DictionaryEntryDetail] {
        let orderedIDs = uniqueOrdered(entryIDs)
        guard orderedIDs.isEmpty == false else { return [] }

        let missing = orderedIDs.filter { detailsByEntryID[$0] == nil }
        if missing.isEmpty == false {
            let fetched = try await DictionarySQLiteStore.shared.fetchEntryDetails(for: missing)
            for detail in fetched {
                detailsByEntryID[detail.entryID] = detail
            }
        }

        return orderedIDs.compactMap { detailsByEntryID[$0] }
    }

    func detail(for entryID: Int64) async throws -> DictionaryEntryDetail? {
        try await details(for: [entryID]).first
    }

    func warm(entryIDs: [Int64]) async {
        _ = try? await details(for: entryIDs)
    }

    func clear() {
        detailsByEntryID = [:]
    }

    private func uniqueOrdered(_ values: [Int64]) -> [Int64] {
        guard values.isEmpty == false else { return [] }
        var out: [Int64] = []
        out.reserveCapacity(values.count)
        var seen: Set<Int64> = []
        for value in values {
            guard seen.insert(value).inserted else { continue }
            out.append(value)
        }
        return out
    }
}

