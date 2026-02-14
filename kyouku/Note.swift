//
//  Note.swift
//  kyouku
//
//  Created by Matthew Morrone on 12/9/25.
//


import Foundation

struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String?
    var text: String
    var createdAt: Date
    var karaokeAudioFileName: String? = nil
    var karaokeAlignment: KaraokeAlignment? = nil
}
