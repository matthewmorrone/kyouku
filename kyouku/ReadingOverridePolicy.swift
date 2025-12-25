import Foundation
import CoreFoundation
import OSLog

actor ReadingOverridePolicy {
    static let shared = ReadingOverridePolicy(loader: {
        try await DictionarySQLiteStore.shared.listDeterministicSurfaceReadings()
    })

    private let loader: () async throws -> [SurfaceReadingOverride]
    private var cachedOverrides: [String: String]?
    private var buildTask: Task<[String: String], Error>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "ReadingOverridePolicy")

    init(loader: @escaping () async throws -> [SurfaceReadingOverride]) {
        self.loader = loader
    }

    func warmUp() async {
        do {
            _ = try await loadOverrides()
        } catch {
            logger.error("ReadingOverridePolicy warmUp failed: \(String(describing: error))")
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
        return normalized.isEmpty ? nil : normalized
    }
}
