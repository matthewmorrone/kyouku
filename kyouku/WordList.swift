import Foundation

/// A user-defined grouping for saved words.
///
/// Stored on-device in JSON (see `WordsStore`).
struct WordList: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
