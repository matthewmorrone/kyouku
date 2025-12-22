import Foundation

struct SharedWord: Codable, Identifiable, Hashable {
    let id: UUID
    let surface: String
    let reading: String
    let meaning: String
}

enum SharedWordsIO {
    private static let fileName = "words.json"

    static func load() -> [SharedWord] {
        guard let url = AppGroup.containerURL()?.appendingPathComponent(fileName) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([SharedWord].self, from: data)
        } catch {
            return []
        }
    }

    static func save(_ words: [SharedWord]) {
        guard let url = AppGroup.containerURL()?.appendingPathComponent(fileName) else { return }
        do {
            let data = try JSONEncoder().encode(words)
            try data.write(to: url, options: .atomic)
        } catch {
            // ignore in app; debug as needed
        }
    }
}

enum AppGroup {
    static let id = "group.com.yourcompany.yourapp"

    static func containerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}
