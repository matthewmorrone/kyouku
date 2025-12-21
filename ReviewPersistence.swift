import Foundation

enum ReviewPersistence {
    private static let wrongKey = "wrongWordIDs"
    private static let lifetimeCorrectKey = "lifetimeCorrectCount"
    private static let lifetimeAgainKey = "lifetimeAgainCount"

    private static func loadIDs() -> Set<UUID> {
        guard let data = UserDefaults.standard.array(forKey: wrongKey) as? [String] else { return [] }
        let ids = data.compactMap { UUID(uuidString: $0) }
        return Set(ids)
    }

    private static func saveIDs(_ ids: Set<UUID>) {
        let strings = ids.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: wrongKey)
    }

    private static func loadCount(forKey key: String) -> Int {
        UserDefaults.standard.integer(forKey: key)
    }

    private static func saveCount(_ value: Int, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
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

    static func incrementCorrect() {
        let current = loadCount(forKey: lifetimeCorrectKey)
        saveCount(current + 1, forKey: lifetimeCorrectKey)
    }

    static func incrementAgain() {
        let current = loadCount(forKey: lifetimeAgainKey)
        saveCount(current + 1, forKey: lifetimeAgainKey)
    }

    static func lifetimeCounts() -> (correct: Int, again: Int) {
        return (loadCount(forKey: lifetimeCorrectKey), loadCount(forKey: lifetimeAgainKey))
    }

    static func lifetimeAccuracy() -> Double? {
        let c = loadCount(forKey: lifetimeCorrectKey)
        let a = loadCount(forKey: lifetimeAgainKey)
        let total = c + a
        guard total > 0 else { return nil }
        return Double(c) / Double(total)
    }
}
