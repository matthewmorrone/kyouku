import Foundation

struct AppBackup: Codable {
    let version: Int
    let exportedAt: Date
    let words: [Word]
    let notes: [Note]
    let readingOverrides: [ReadingOverride]

    init(version: Int, exportedAt: Date, words: [Word], notes: [Note], readingOverrides: [ReadingOverride]) {
        self.version = version
        self.exportedAt = exportedAt
        self.words = words
        self.notes = notes
        self.readingOverrides = readingOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case exportedAt
        case words
        case notes
        case readingOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        words = try container.decode([Word].self, forKey: .words)
        notes = try container.decode([Note].self, forKey: .notes)
        readingOverrides = try container.decodeIfPresent([ReadingOverride].self, forKey: .readingOverrides) ?? []
    }
}

enum AppDataBackup {
    static func exportData(words: [Word], notes: [Note], readingOverrides: [ReadingOverride]) throws -> URL {
        let backup = AppBackup(version: 1, exportedAt: Date(), words: words, notes: notes, readingOverrides: readingOverrides)
        let data = try JSONEncoder().encode(backup)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kyouku-backup-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: tmp, options: .atomic)
        return tmp
    }

    static func importData(from url: URL) throws -> AppBackup {
        let data = try Data(contentsOf: url)
        let backup = try JSONDecoder().decode(AppBackup.self, from: data)
        return backup
    }
}
