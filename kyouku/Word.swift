//
//  Word.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//

import Foundation

struct Word: Identifiable, Codable, Hashable {
    let id: UUID
    var surface: String
    var kana: String
    var meaning: String
    var note: String?
    var sourceNoteID: UUID? = nil
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        surface: String,
        kana: String,
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

