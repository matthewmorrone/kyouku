import Foundation

enum ReviewPersistence {
    private static let wrongKey = "wrongWordIDs"

    private static func loadIDs() -> Set<UUID> {
        guard let data = UserDefaults.standard.array(forKey: wrongKey) as? [String] else { return [] }
        let ids = data.compactMap { UUID(uuidString: $0) }
        return Set(ids)
    }

    private static func saveIDs(_ ids: Set<UUID>) {
        let strings = ids.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: wrongKey)
    }

    static func allWrong() -> Set<UUID> {
        loadIDs()
    }

    static func markWrong(_ id: UUID) {
        var ids = loadIDs()
        ids.insert(id)
        saveIDs(ids)
    }

    static func markRight(_ id: UUID) {
        var ids = loadIDs()
        ids.remove(id)
        saveIDs(ids)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: wrongKey)
    }
}
