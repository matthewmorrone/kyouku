import Foundation
import Combine

@MainActor
final class ViewedDictionaryHistoryStore: ObservableObject {
    static let shared = ViewedDictionaryHistoryStore()

    struct Item: Identifiable, Codable, Hashable {
        let id: String
        var surface: String
        var kana: String?
        var lastViewedAt: Date

        init(surface: String, kana: String?, lastViewedAt: Date = Date()) {
            let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedKana = kana?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = ViewedDictionaryHistoryStore.key(surface: normalizedSurface, kana: normalizedKana)
            self.id = key
            self.surface = normalizedSurface
            self.kana = (normalizedKana?.isEmpty == false) ? normalizedKana : nil
            self.lastViewedAt = lastViewedAt
        }
    }

    @Published private(set) var items: [Item] = []

    private static let storageKey = "viewedDictionaryHistoryV1"
    private static let maxItems = 250

    private init() {
        load()
    }

    func record(surface: String, kana: String?) {
        let normalizedSurface = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKana = kana?.trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedSurface.isEmpty && (normalizedKana?.isEmpty ?? true) {
            return
        }

        let key = Self.key(surface: normalizedSurface, kana: normalizedKana)
        let now = Date()

        if let idx = items.firstIndex(where: { $0.id == key }) {
            var updated = items[idx]
            updated.surface = normalizedSurface.isEmpty ? (updated.surface) : normalizedSurface
            updated.kana = (normalizedKana?.isEmpty == false) ? normalizedKana : nil
            updated.lastViewedAt = now
            items.remove(at: idx)
            items.insert(updated, at: 0)
        } else {
            items.insert(Item(surface: normalizedSurface, kana: normalizedKana, lastViewedAt: now), at: 0)
            if items.count > Self.maxItems {
                items = Array(items.prefix(Self.maxItems))
            }
        }

        persist()
    }

    func remove(id: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: idx)
            persist()
        }
    }

    func clear() {
        guard items.isEmpty == false else { return }
        items.removeAll()
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else {
            items = []
            return
        }

        do {
            let decoded = try JSONDecoder().decode([Item].self, from: data)
            items = decoded.sorted(by: { $0.lastViewedAt > $1.lastViewedAt })
        } catch {
            items = []
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            // ignore
        }
    }

    private static func key(surface: String, kana: String?) -> String {
        let primary = surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = (kana ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(primary)|\(secondary)"
    }
}
