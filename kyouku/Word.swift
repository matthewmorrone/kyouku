import Foundation

struct Word: Identifiable, Codable, Hashable {
    let id: UUID
    var surface: String
    var reading: String
    var meaning: String
    var note: String?
    var createdAt: Date
    
    init(
        id: UUID = UUID(),
        surface: String,
        reading: String,
        meaning: String,
        note: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.surface = surface
        self.reading = reading
        self.meaning = meaning
        self.note = note
        self.createdAt = createdAt
    }
}
