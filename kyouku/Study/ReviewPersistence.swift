import Foundation

enum ReviewPersistence {
    private static let wrongKey = "wrongWordIDs"
    private static let lifetimeCorrectKey = "lifetimeCorrectCount"
    private static let lifetimeAgainKey = "lifetimeAgainCount"
    private static let perWordStatsKey = "wordReviewStatsV1"

    struct WordStats: Codable, Hashable {
        var correct: Int
        var again: Int
        var lastReviewedAt: Date?

        var total: Int { correct + again }

        var accuracy: Double? {
            let t = total
            guard t > 0 else { return nil }
            return Double(correct) / Double(t)
        }
    }

    private static func loadPerWordStats() -> [UUID: WordStats] {
        guard let data = UserDefaults.standard.data(forKey: perWordStatsKey) else { return [:] }
        do {
            let decoded = try JSONDecoder().decode([String: WordStats].self, from: data)
            var out: [UUID: WordStats] = [:]
            out.reserveCapacity(decoded.count)
            for (k, v) in decoded {
                if let id = UUID(uuidString: k) {
                    out[id] = v
                }
            }
            return out
        } catch {
            return [:]
        }
    }

    private static func savePerWordStats(_ stats: [UUID: WordStats]) {
        var encodable: [String: WordStats] = [:]
        encodable.reserveCapacity(stats.count)
        for (id, st) in stats {
            encodable[id.uuidString] = st
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: perWordStatsKey)
    }

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

    static func recordAgain(for id: UUID) {
        var stats = loadPerWordStats()
        var st = stats[id] ?? WordStats(correct: 0, again: 0, lastReviewedAt: nil)
        st.again += 1
        st.lastReviewedAt = Date()
        stats[id] = st
        savePerWordStats(stats)
    }

    static func recordCorrect(for id: UUID) {
        var stats = loadPerWordStats()
        var st = stats[id] ?? WordStats(correct: 0, again: 0, lastReviewedAt: nil)
        st.correct += 1
        st.lastReviewedAt = Date()
        stats[id] = st
        savePerWordStats(stats)
    }

    static func stats(for id: UUID) -> WordStats? {
        loadPerWordStats()[id]
    }

    /// Returns a 0..1 accuracy score, or nil if there isn't enough signal.
    static func learnedScore(for id: UUID, minimumReviews: Int = FuriganaKnownWordsSettings.defaultMinimumReviews) -> Double? {
        if allWrong().contains(id) { return nil }
        guard let st = stats(for: id) else { return nil }
        let minReviews = max(1, minimumReviews)
        guard st.total >= minReviews else { return nil }
        return st.accuracy
    }

    static func incrementCorrect() {
        let current = loadCount(forKey: lifetimeCorrectKey)
        saveCount(current + 1, forKey: lifetimeCorrectKey)
    }

    static func incrementAgain() {
        let current = loadCount(forKey: lifetimeAgainKey)
        saveCount(current + 1, forKey: lifetimeAgainKey)
    }

    static func lifetimeAccuracy() -> Double? {
        let c = loadCount(forKey: lifetimeCorrectKey)
        let a = loadCount(forKey: lifetimeAgainKey)
        let total = c + a
        guard total > 0 else { return nil }
        return Double(c) / Double(total)
    }
}
