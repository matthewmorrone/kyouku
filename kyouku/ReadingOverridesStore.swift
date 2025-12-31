import Foundation
import Combine
import OSLog

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
    /// Optional user-confirmed kana for this range. `nil` means "trust the automatic reading" while still forcing token boundaries.
    let userKana: String?
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case noteID
        case rangeStart
        case rangeLength
        case userKana = "kana"
        case createdAt
    }

    init(id: UUID = UUID(), noteID: UUID, rangeStart: Int, rangeLength: Int, userKana: String?, createdAt: Date = Date()) {
        self.id = id
        self.noteID = noteID
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        if let trimmed = userKana?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false {
            self.userKana = trimmed
        } else {
            self.userKana = nil
        }
        self.createdAt = createdAt
    }

    var nsRange: NSRange {
        NSRange(location: rangeStart, length: rangeLength)
    }

    func overlaps(_ otherRange: NSRange) -> Bool {
        NSIntersectionRange(nsRange, otherRange).length > 0
    }
}

/// Stores user-confirmed reading overrides on disk.
///
/// Only explicit user actions (e.g., tapping "Use this reading") should call
/// `saveOverride`. Heuristic furigana inference must *never* persist data via
/// this store; inferred readings should be treated as provisional display aids.
final class ReadingOverridesStore: ObservableObject {
    @Published private(set) var overrides: [ReadingOverride] = []
    private static let logger = DiagnosticsLogging.logger(.readingOverrides)

    private let fileName = "reading-overrides.json"

    init() {
        load()
    }

    func overrides(for noteID: UUID) -> [ReadingOverride] {
        overrides.filter { $0.noteID == noteID }
    }

    func overrides(for noteID: UUID, overlapping range: NSRange) -> [ReadingOverride] {
        overrides.filter { $0.noteID == noteID && $0.overlaps(range) }
    }

    func upsert(noteID: UUID, range: NSRange, userKana: String?) {
        let override = ReadingOverride(
            noteID: noteID,
            rangeStart: range.location,
            rangeLength: range.length,
            userKana: userKana
        )
        Self.logger.debug("Upsert override note=\(noteID) range=\(range.location)-\(NSMaxRange(range)) hasKana=\(userKana != nil)")
        apply(noteID: noteID, removing: range, adding: [override])
    }

    func apply(noteID: UUID, removing range: NSRange, adding newOverrides: [ReadingOverride]) {
        overrides.removeAll { $0.noteID == noteID && $0.overlaps(range) }
        overrides.append(contentsOf: newOverrides)
        save()
        Self.logger.debug("Applied overrides note=\(noteID) removeRange=\(range.location)-\(NSMaxRange(range)) inserted=\(newOverrides.count) total=\(self.overrides.count)")
        notifyChange()
    }

    func remove(noteID: UUID, in range: NSRange) {
        let before = overrides.count
        overrides.removeAll { $0.noteID == noteID && $0.overlaps(range) }
        if overrides.count != before {
            save()
            Self.logger.debug("Removed overrides note=\(noteID) range=\(range.location)-\(NSMaxRange(range)) remaining=\(self.overrides.count)")
            notifyChange()
        }
    }

    func removeAll(for noteID: UUID) {
        let before = overrides.count
        overrides.removeAll { $0.noteID == noteID }
        guard overrides.count != before else { return }
        save()
        Self.logger.debug("Removed all overrides for note=\(noteID) remaining=\(self.overrides.count)")
        notifyChange()
    }

    func removeBoundaryOverrides(for noteID: UUID) {
        let before = overrides.count
        overrides.removeAll { $0.noteID == noteID && $0.userKana == nil }
        guard overrides.count != before else { return }
        save()
        Self.logger.debug("Removed boundary-only overrides for note=\(noteID) remaining=\(self.overrides.count)")
        notifyChange()
    }

    func deleteOverride(id: UUID) {
        let before = overrides.count
        overrides.removeAll { $0.id == id }
        if overrides.count != before {
            save()
            Self.logger.debug("Deleted override id=\(id) remaining=\(self.overrides.count)")
            notifyChange()
        }
    }

    func replaceAll(with overrides: [ReadingOverride]) {
        self.overrides = overrides
        save()
        Self.logger.debug("Replaced all overrides count=\(overrides.count)")
        notifyChange()
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
            Self.logger.debug("Loaded overrides file entries=\(self.overrides.count)")
        } catch {
            Self.logger.error("Failed to load reading overrides: \(error.localizedDescription, privacy: .public)")
            print("Failed to load reading overrides: \(error)")
        }
    }

    private func save() {
        guard let url = fileURL() else { return }
        do {
            let data = try JSONEncoder().encode(overrides)
            try data.write(to: url, options: .atomic)
            Self.logger.debug("Saved overrides count=\(self.overrides.count)")
        } catch {
            Self.logger.error("Failed to save reading overrides: \(error.localizedDescription, privacy: .public)")
            print("Failed to save reading overrides: \(error)")
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .readingOverridesDidChange, object: self)
    }
}

extension Notification.Name {
    static let readingOverridesDidChange = Notification.Name("ReadingOverridesDidChange")
}
