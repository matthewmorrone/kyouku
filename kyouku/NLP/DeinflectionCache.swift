import Foundation

/// Per-session deinflection cache.
///
/// This keeps deinflection work off hot paths by memoizing results per unique surface.
actor DeinflectionCache {
    private var cache: [String: [Deinflector.Candidate]] = [:]
    private var deinflector: Deinflector?

    private func getDeinflector() async -> Deinflector? {
        if let d = deinflector { return d }
        do {
            // In Swift 6 projects which default to MainActor isolation, Deinflector may be
            // inferred as MainActor-isolated. Hopping is cheap and keeps this cache usable
            // from background tasks.
            let loaded = try await MainActor.run { try Deinflector.loadBundled(named: "deinflect") }
            deinflector = loaded
            return loaded
        } catch {
            deinflector = nil
            return nil
        }
    }

    func candidates(for surface: String, maxDepth: Int = 8, maxResults: Int = 48) async -> [Deinflector.Candidate] {
        let key = surface
        if let existing = cache[key] {
            return existing
        }

        guard let deinflector = await getDeinflector() else {
            cache[key] = []
            return []
        }

        let results = await MainActor.run { deinflector.deinflect(surface, maxDepth: maxDepth, maxResults: maxResults) }
        cache[key] = results
        return results
    }
}
