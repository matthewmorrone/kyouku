import Foundation
import CoreFoundation

actor ReadingOverridePolicy {
    static let shared = ReadingOverridePolicy(loader: {
        try await DictionarySQLiteStore.shared.listDeterministicSurfaceReadings()
    })

    private let loader: () async throws -> [SurfaceReadingOverride]
    private var cachedOverrides: [String: String]?
    private var buildTask: Task<[String: String], Error>?

    init(loader: @escaping () async throws -> [SurfaceReadingOverride]) {
        self.loader = loader
    }

    func warmUp() async {
        do {
            _ = try await loadOverrides()
        } catch {
            await CustomLogger.shared.error("ReadingOverridePolicy warmUp failed: \(String(describing: error))")
        }
    }

    func overrideReading(for surface: String, mecabReading: String?) async -> String? {
        guard surface.isEmpty == false else { return nil }
        let rawSurface = surface.precomposedStringWithCanonicalMapping
        let key = Self.normalizeSurface(surface)
        if let overrides = await cachedOverridesOrStartWarmUp(),
           let dictionaryReading = overrides[key] {
            if let mecabNormalized = Self.normalizeReading(mecabReading), mecabNormalized == dictionaryReading {
                return nil
            }
            return dictionaryReading
        }

        // Generic fallback for glyph-variant surfaces when cache is not ready yet.
        // Example: 噓 -> 嘘 via normalizeForLookup.
        guard key != rawSurface else { return nil }
        guard let dictionaryReading = await fallbackCanonicalReading(for: key) else { return nil }
        if let mecabNormalized = Self.normalizeReading(mecabReading), mecabNormalized == dictionaryReading {
            return nil
        }
        return dictionaryReading
    }

    private func fallbackCanonicalReading(for canonicalSurface: String) async -> String? {
        guard canonicalSurface.isEmpty == false else { return nil }

        let rows = (try? await DictionarySQLiteStore.shared.lookupExact(term: canonicalSurface, limit: 20)) ?? []
        guard rows.isEmpty == false else { return nil }

        var normalizedReadings: Set<String> = []
        normalizedReadings.reserveCapacity(rows.count)

        for row in rows {
            if let reading = Self.normalizeReading(row.kana) {
                normalizedReadings.insert(reading)
            }
        }

        if normalizedReadings.count == 1 {
            return normalizedReadings.first
        }

        let entryIDs = rows.map(\.entryID)
        let details = (try? await DictionaryEntryDetailsCache.shared.details(for: entryIDs)) ?? []
        for detail in details {
            for form in detail.kanaForms {
                if let reading = Self.normalizeReading(form.text) {
                    normalizedReadings.insert(reading)
                }
            }
        }

        guard normalizedReadings.count == 1 else { return nil }
        return normalizedReadings.first
    }

    private func cachedOverridesOrStartWarmUp() async -> [String: String]? {
        if let cached = cachedOverrides {
            return cached
        }

        // Render path guardrail:
        // Do not block furigana/token rendering on first-use DB bootstrap.
        // Start hydration in the background and return fast until warm.
        startBuildTaskIfNeeded()

        return nil
    }

    private func loadOverrides() async throws -> [String: String] {
        if let cached = cachedOverrides { return cached }
        startBuildTaskIfNeeded()
        guard let task = buildTask else { return [:] }

        do {
            let built = try await task.value
            cachedOverrides = built
            buildTask = nil
            return built
        } catch {
            buildTask = nil
            throw error
        }
    }

    private func startBuildTaskIfNeeded() {
        if cachedOverrides != nil || buildTask != nil {
            return
        }

        // Capture actor-isolated state before entering the Task closure.
        let loader = self.loader

        let task = Task<[String: String], Error> {
            let records = try await loader()
            var map: [String: String] = [:]
            var conflicted: Set<String> = []
            map.reserveCapacity(records.count)
            for record in records {
                let surface = Self.normalizeSurface(record.surface)
                guard surface.isEmpty == false else { continue }
                guard let reading = Self.normalizeReading(record.reading) else { continue }

                if let existing = map[surface] {
                    if existing != reading {
                        conflicted.insert(surface)
                        map[surface] = nil
                    }
                    continue
                }

                if conflicted.contains(surface) == false {
                    map[surface] = reading
                }
            }
            return map
        }
        buildTask = task
    }

    private static func normalizeSurface(_ surface: String) -> String {
        normalizeForLookup(surface)
    }

    private static func normalizeReading(_ reading: String?) -> String? {
        guard let reading else { return nil }
        let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let mutable = NSMutableString(string: trimmed) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        let normalized = (mutable as String).precomposedStringWithCanonicalMapping
        guard normalized.isEmpty == false else { return nil }
        // Readings must be kana. If the DB contains an unexpected glyph (e.g. kanji),
        // ignore it rather than propagating it into ruby rendering.
        let containsKanji = normalized.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if containsKanji { return nil }
        let containsKana = normalized.unicodeScalars.contains { (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value) }
        if containsKana == false { return nil }
        return normalized
    }
}
