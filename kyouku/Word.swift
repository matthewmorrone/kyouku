//
//  Word.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation

/// A vocabulary item saved from a dictionary lookup.
///
/// - Note: `kana` stores the dictionary-provided kana reading for the entry.
///   It may be `nil` when the dictionary offers no kana, and it is never
///   populated from pasted text or heuristic furigana. When a user confirms a
///   correction, that override is stored separately via `ReadingOverride` and
///   does not mutate this model.
struct Word: Identifiable, Codable, Hashable {
    let id: UUID
    var surface: String
    /// Authoritative dictionary kana reading (if provided), never inferred from user text.
    var kana: String?
    var meaning: String
    var note: String?
    var sourceNoteID: UUID? = nil
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        surface: String,
        kana: String? = nil,
        meaning: String,
        note: String? = nil,
        sourceNoteID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.surface = surface
        self.kana = kana
        self.meaning = meaning
        self.note = note
        self.sourceNoteID = sourceNoteID
        self.createdAt = createdAt
    }
}

