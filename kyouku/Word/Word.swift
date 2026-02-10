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
    /// IDs of notes this word is associated with (e.g. where it was saved from).
    /// Empty means the word is not note-scoped (created from Words tab / import, etc.).
    var sourceNoteIDs: [UUID] = []
    /// IDs of user-defined lists this word belongs to.
    /// Optional/backward-compatible: older saved files won’t include this key.
    var listIDs: [UUID] = []
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        surface: String,
        dictionarySurface: String? = nil,
        kana: String? = nil,
        meaning: String,
        note: String? = nil,
        sourceNoteID: UUID? = nil,
        listIDs: [UUID] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.surface = surface
        self.dictionarySurface = dictionarySurface
        self.kana = kana
        self.meaning = meaning
        self.note = note
        if let sourceNoteID {
            self.sourceNoteIDs = [sourceNoteID]
        } else {
            self.sourceNoteIDs = []
        }
        self.listIDs = listIDs
        self.createdAt = createdAt
    }

    func isAssociated(with noteID: UUID?) -> Bool {
        if let noteID {
            return sourceNoteIDs.contains(noteID)
        }
        return sourceNoteIDs.isEmpty
    }
}

// MARK: - Backward-compatible Codable
extension Word {
    private enum CodingKeys: String, CodingKey {
        case id
        case surface
        case dictionarySurface
        case kana
        case meaning
        case note
        case sourceNoteID
        case sourceNoteIDs
        case listIDs
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        surface = try container.decode(String.self, forKey: .surface)
        dictionarySurface = try container.decodeIfPresent(String.self, forKey: .dictionarySurface)
        kana = try container.decodeIfPresent(String.self, forKey: .kana)
        meaning = try container.decode(String.self, forKey: .meaning)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        let decodedIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceNoteIDs)
        if let decodedIDs {
            sourceNoteIDs = decodedIDs
        } else if let single = try container.decodeIfPresent(UUID.self, forKey: .sourceNoteID) {
            sourceNoteIDs = [single]
        } else {
            sourceNoteIDs = []
        }
        listIDs = try container.decodeIfPresent([UUID].self, forKey: .listIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(surface, forKey: .surface)
        try container.encodeIfPresent(dictionarySurface, forKey: .dictionarySurface)
        try container.encodeIfPresent(kana, forKey: .kana)
        try container.encode(meaning, forKey: .meaning)
        try container.encodeIfPresent(note, forKey: .note)

        // Write both keys for forward/backward compatibility.
        if sourceNoteIDs.isEmpty == false {
            try container.encode(sourceNoteIDs, forKey: .sourceNoteIDs)
            try container.encodeIfPresent(sourceNoteIDs.first, forKey: .sourceNoteID)
        } else {
            try container.encode([UUID](), forKey: .sourceNoteIDs)
            try container.encodeNil(forKey: .sourceNoteID)
        }

        try container.encode(listIDs, forKey: .listIDs)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

