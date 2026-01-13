//
//  Word.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation

/// A vocabulary item saved from a dictionary lookup.
///
/// - Note: `kana` stores the reading the user saved alongside the surface.
///   This is usually the dictionary-provided kana, but when the user has an
///   explicit reading override active it may reflect that override.
///   It is never populated from pasted text or heuristic furigana.
struct Word: Identifiable, Codable, Hashable {
    let id: UUID
    var surface: String
    /// Optional dictionary headword surface used for lookups (can differ from `surface`
    /// when the note contains an inflected form). Kept optional for backward compatibility.
    var dictionarySurface: String? = nil
    /// Authoritative dictionary kana reading (if provided), never inferred from user text.
    var kana: String?
    var meaning: String
    var note: String?
    var sourceNoteID: UUID? = nil
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        surface: String,
        dictionarySurface: String? = nil,
        kana: String? = nil,
        meaning: String,
        note: String? = nil,
        sourceNoteID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.surface = surface
        self.dictionarySurface = dictionarySurface
        self.kana = kana
        self.meaning = meaning
        self.note = note
        self.sourceNoteID = sourceNoteID
        self.createdAt = createdAt
    }
}

