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
        guard let overrides = try? await loadOverrides() else { return nil }
        let key = Self.normalizeSurface(surface)
        guard let dictionaryReading = overrides[key] else { return nil }
        if let mecabNormalized = Self.normalizeReading(mecabReading), mecabNormalized == dictionaryReading {
            return nil
        }
        return dictionaryReading
    }

    private func loadOverrides() async throws -> [String: String] {
        if let cached = cachedOverrides { return cached }
        if let task = buildTask { return try await task.value }

        // Capture actor-isolated state before entering the Task closure.
        let loader = self.loader

        let task = Task<[String: String], Error> {
            let records = try await loader()
            var map: [String: String] = [:]
            map.reserveCapacity(records.count)
            for record in records {
                let surface = Self.normalizeSurface(record.surface)
                guard surface.isEmpty == false else { continue }
                guard let reading = Self.normalizeReading(record.reading) else { continue }
                map[surface] = reading
            }
            return map
        }
        buildTask = task

        let built = try await task.value
        cachedOverrides = built
        buildTask = nil
        return built
    }

    private static func normalizeSurface(_ surface: String) -> String {
        surface.precomposedStringWithCanonicalMapping
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
