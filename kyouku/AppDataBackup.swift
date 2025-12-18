import Foundation

struct AppBackup: Codable {
    let version: Int
    let exportedAt: Date
    let words: [Word]
    let notes: [Note]
}

enum AppDataBackup {
    static func exportData(words: [Word], notes: [Note]) throws -> URL {
        let backup = AppBackup(version: 1, exportedAt: Date(), words: words, notes: notes)
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
