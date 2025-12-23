import Foundation
import Combine

/// Describes a single user-confirmed reading override for text inside a note.
///
/// - Dictionary `kana` values live on `DictionaryEntry`/`Word` and remain
///   authoritative only for dictionary contexts.
/// - Inferred readings (e.g., heuristics that might power future furigana
///   displays) are transient, never persisted, and never update dictionary
///   data.
/// - `ReadingOverride` records exist only when a human explicitly confirms a
///   correction. They are scoped to a note, reference a plain-text range, and
///   never modify dictionary `kana` values.
struct ReadingOverride: Identifiable, Codable, Hashable {
    let id: UUID
    let noteID: UUID
    /// Offset into the note's plain-text `content`, measured in UTF-16 code units to match `NSRange` semantics.
    let rangeStart: Int
    /// Length of the overridden segment, also measured in UTF-16 code units.
    let rangeLength: Int
    /// User-confirmed kana for this range; never reinterpret this as dictionary-provided `kana`.
    let userKana: String
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case noteID
        case rangeStart
        case rangeLength
        case userKana = "kana"
        case createdAt
    }

    init(id: UUID = UUID(), noteID: UUID, rangeStart: Int, rangeLength: Int, userKana: String, createdAt: Date = Date()) {
        self.id = id
        self.noteID = noteID
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        self.userKana = userKana
        self.createdAt = createdAt
    }
}

/// Stores user-confirmed reading overrides on disk.
///
/// Only explicit user actions (e.g., tapping "Use this reading") should call
/// `saveOverride`. Heuristic furigana inference must *never* persist data via
/// this store; inferred readings should be treated as provisional display aids.
final class ReadingOverridesStore: ObservableObject {
    @Published private(set) var overrides: [ReadingOverride] = []

    private let fileName = "reading-overrides.json"

    init() {
        load()
    }

    func overrides(for noteID: UUID) -> [ReadingOverride] {
        overrides.filter { $0.noteID == noteID }
    }

    func saveOverride(noteID: UUID, range: NSRange, userKana: String) {
        let trimmed = userKana.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let newOverride = ReadingOverride(noteID: noteID, rangeStart: range.location, rangeLength: range.length, userKana: trimmed)
        overrides.removeAll { $0.noteID == noteID && $0.rangeStart == range.location && $0.rangeLength == range.length }
        overrides.append(newOverride)
        save()
    }

    func deleteOverride(id: UUID) {
        let before = overrides.count
        overrides.removeAll { $0.id == id }
        if overrides.count != before {
            save()
        }
    }

    func replaceAll(with overrides: [ReadingOverride]) {
        self.overrides = overrides
        save()
    }

    func allOverrides() -> [ReadingOverride] {
        overrides
    }

    // MARK: - Persistence

    private func documentsURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private func fileURL() -> URL? {
        documentsURL()?.appendingPathComponent(fileName)
    }

    private func load() {
        guard let url = fileURL(), FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            overrides = try JSONDecoder().decode([ReadingOverride].self, from: data)
        } catch {
            print("Failed to load reading overrides: \(error)")
        }
    }

    private func save() {
        guard let url = fileURL() else { return }
        do {
            let data = try JSONEncoder().encode(overrides)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save reading overrides: \(error)")
        }
    }
}
