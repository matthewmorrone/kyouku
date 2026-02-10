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

