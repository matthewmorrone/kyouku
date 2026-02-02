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
    /// Optional local filename in Documents for a user-attached audio recording.
    /// Used for karaoke-style playback highlighting.
    var audioFilename: String?
    var createdAt: Date
}
