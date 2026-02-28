import Foundation
import Combine

@MainActor
final class TokenBoundariesStore: ObservableObject {
    struct StoredSpan: Codable, Hashable {
        let start: Int
        let length: Int
        let isLexiconMatch: Bool
    }

    private struct PersistedPayload: Codable {
        var spansByNote: [UUID: [StoredSpan]]
        var hardCutsByNote: [UUID: [Int]]
        var textSignatureByNote: [UUID: UInt64]

        init(
            spansByNote: [UUID: [StoredSpan]],
            hardCutsByNote: [UUID: [Int]],
            textSignatureByNote: [UUID: UInt64]
        ) {
            self.spansByNote = spansByNote
            self.hardCutsByNote = hardCutsByNote
            self.textSignatureByNote = textSignatureByNote
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            spansByNote = try container.decodeIfPresent([UUID: [StoredSpan]].self, forKey: .spansByNote) ?? [:]
            hardCutsByNote = try container.decodeIfPresent([UUID: [Int]].self, forKey: .hardCutsByNote) ?? [:]
            textSignatureByNote = try container.decodeIfPresent([UUID: UInt64].self, forKey: .textSignatureByNote) ?? [:]
        }
    }

    @Published private(set) var spansByNote: [UUID: [StoredSpan]] = [:]
    @Published private(set) var hardCutsByNote: [UUID: [Int]] = [:]
    @Published private(set) var spacingByNote: [UUID: [Int: Double]] = [:]
    @Published private(set) var textSignatureByNote: [UUID: UInt64] = [:]

    private let fileName = "token-spans.json"

    init() {
        load()
    }

    func hasCustomSpans(for noteID: UUID) -> Bool {
        (spansByNote[noteID]?.isEmpty == false)
    }

    func hardCuts(for noteID: UUID, text: String) -> [Int] {
        guard let cuts = hardCutsByNote[noteID], cuts.isEmpty == false else { return [] }
        let length = (text as NSString).length
        guard length > 0 else { return [] }
        guard noteDataMatchesText(noteID: noteID, text: text) else {
            invalidateStaleNoteData(noteID: noteID)
            return []
        }
        return cuts
            .filter { $0 > 0 && $0 < length }
            .sorted()
    }

    func addHardCut(noteID: UUID, utf16Index: Int, text: String) {
        let length = (text as NSString).length
        guard length > 0 else { return }
        guard utf16Index > 0, utf16Index < length else { return }
        var existing = Set(hardCutsByNote[noteID] ?? [])
        let inserted = existing.insert(utf16Index).inserted
        guard inserted else { return }
        hardCutsByNote[noteID] = existing.sorted()
        textSignatureByNote[noteID] = textSignature(text)
        save()
    }

    func addHardCuts(noteID: UUID, utf16Indices: [Int], text: String) {
        guard utf16Indices.isEmpty == false else { return }
        let length = (text as NSString).length
        guard length > 0 else { return }

        var existing = Set(hardCutsByNote[noteID] ?? [])
        let beforeCount = existing.count
        for idx in utf16Indices {
            guard idx > 0, idx < length else { continue }
            existing.insert(idx)
        }
        guard existing.count != beforeCount else { return }
        hardCutsByNote[noteID] = existing.sorted()
        textSignatureByNote[noteID] = textSignature(text)
        save()
    }

    // MARK: - Inter-token spacing

    private var interTokenSpacingEpsilon: CGFloat { TokenSpacingInvariantSource.tokenSpacingExistingWidthEpsilon }

    func interTokenSpacing(for noteID: UUID, text: String) -> [Int: CGFloat] {
        guard let raw = spacingByNote[noteID], raw.isEmpty == false else { return [:] }
        let length = (text as NSString).length
        guard length > 0 else { return [:] }

        var result: [Int: CGFloat] = [:]
        result.reserveCapacity(raw.count)

        for (idx, width) in raw {
            guard idx > 0, idx < length else { continue }
            guard width.isFinite else { continue }
            let w = TokenSpacingInvariantSource.clampTokenSpacingWidth(CGFloat(width))
            guard abs(w) > interTokenSpacingEpsilon else { continue }

            // Avoid adding spacing at explicit line breaks.
            let scalar = (text as NSString).character(at: idx)
            if let u = UnicodeScalar(scalar), CharacterSet.newlines.contains(u) {
                continue
            }
            result[idx] = w
        }

        return result
    }

    func interTokenSpacingWidth(noteID: UUID, boundaryUTF16Index: Int) -> CGFloat {
        guard let raw = spacingByNote[noteID] else { return 0 }
        let width = raw[boundaryUTF16Index] ?? 0
        guard width.isFinite else { return 0 }
        return TokenSpacingInvariantSource.clampTokenSpacingWidth(CGFloat(width))
    }

    func setInterTokenSpacing(noteID: UUID, boundaryUTF16Index: Int, width: CGFloat, text: String) {
        let length = (text as NSString).length
        guard length > 0 else { return }
        guard boundaryUTF16Index > 0, boundaryUTF16Index < length else { return }
        guard width.isFinite else { return }

        // Avoid setting spacing at explicit line breaks.
        let scalar = (text as NSString).character(at: boundaryUTF16Index)
        if let u = UnicodeScalar(scalar), CharacterSet.newlines.contains(u) {
            return
        }

        let clamped = TokenSpacingInvariantSource.clampTokenSpacingWidth(width)
        if abs(clamped) <= interTokenSpacingEpsilon {
            removeInterTokenSpacing(noteID: noteID, boundaryUTF16Index: boundaryUTF16Index)
            return
        }

        var dict = spacingByNote[noteID] ?? [:]
        let old = dict[boundaryUTF16Index] ?? 0
        if abs(old - Double(clamped)) < Double(interTokenSpacingEpsilon) {
            return
        }
        dict[boundaryUTF16Index] = Double(clamped)
        spacingByNote[noteID] = dict
    }

    func removeInterTokenSpacing(noteID: UUID, boundaryUTF16Index: Int) {
        guard var dict = spacingByNote[noteID] else { return }
        guard dict.removeValue(forKey: boundaryUTF16Index) != nil else { return }
        if dict.isEmpty {
            spacingByNote[noteID] = nil
        } else {
            spacingByNote[noteID] = dict
        }
    }

    func resetInterTokenSpacing(noteID: UUID, boundaryUTF16Indices: [Int]) {
        guard boundaryUTF16Indices.isEmpty == false else { return }
        guard var dict = spacingByNote[noteID], dict.isEmpty == false else { return }
        let beforeCount = dict.count
        for idx in boundaryUTF16Indices {
            dict.removeValue(forKey: idx)
        }
        guard dict.count != beforeCount else { return }
        spacingByNote[noteID] = dict.isEmpty ? nil : dict
    }

    func storedRanges(for noteID: UUID) -> [NSRange] {
        guard let stored = spansByNote[noteID], stored.isEmpty == false else { return [] }
        return stored.map { NSRange(location: $0.start, length: $0.length) }
    }

    func snapshot(for noteID: UUID) -> [StoredSpan]? {
        spansByNote[noteID]
    }

    func restore(noteID: UUID, snapshot: [StoredSpan]?) {
        if let snapshot, snapshot.isEmpty == false {
            spansByNote[noteID] = snapshot
        } else {
            spansByNote[noteID] = nil
        }
        save()
    }

    func spans(for noteID: UUID, text: String) -> [TextSpan]? {
        guard let stored = spansByNote[noteID], stored.isEmpty == false else { return nil }
        guard noteDataMatchesText(noteID: noteID, text: text) else {
            invalidateStaleNoteData(noteID: noteID)
            return nil
        }
        let nsText = text as NSString
        let textLength = nsText.length
        guard textLength > 0 else { return [] }
        var spans: [TextSpan] = []
        spans.reserveCapacity(stored.count)
        for entry in stored {
            guard entry.start >= 0, entry.length > 0 else { continue }
            guard entry.start < textLength else { continue }
            let end = min(entry.start + entry.length, textLength)
            guard end > entry.start else { continue }
            let range = NSRange(location: entry.start, length: end - entry.start)
            let surface = nsText.substring(with: range)
            spans.append(TextSpan(range: range, surface: surface, isLexiconMatch: entry.isLexiconMatch))
        }
        return spans.isEmpty ? nil : spans
    }

    func setSpans(noteID: UUID, spans: [TextSpan], text: String) {
        let nsText = text as NSString
        let textLength = nsText.length
        let cleaned: [StoredSpan] = spans
            .map { span in
                let start = max(0, span.range.location)
                let end = min(NSMaxRange(span.range), textLength)
                return StoredSpan(start: start, length: max(0, end - start), isLexiconMatch: span.isLexiconMatch)
            }
            .filter { $0.length > 0 }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.length < rhs.length }
                return lhs.start < rhs.start
            }

        if cleaned.isEmpty {
            spansByNote[noteID] = nil
        } else {
            spansByNote[noteID] = cleaned
        }
        textSignatureByNote[noteID] = textSignature(text)
        save()
    }

    func removeAll(for noteID: UUID) {
        let removedSpans = spansByNote.removeValue(forKey: noteID) != nil
        let removedCuts = hardCutsByNote.removeValue(forKey: noteID) != nil
        let removedSpacing = spacingByNote.removeValue(forKey: noteID) != nil
        let removedSignature = textSignatureByNote.removeValue(forKey: noteID) != nil
        guard removedSpans || removedCuts || removedSpacing || removedSignature else { return }
        // Inter-token spacing is intentionally not persisted.
        if removedSpans || removedCuts {
            save()
        }
    }

    private func noteDataMatchesText(noteID: UUID, text: String) -> Bool {
        guard let storedSignature = textSignatureByNote[noteID] else { return false }
        return storedSignature == textSignature(text)
    }

    private func textSignature(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for scalar in text.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 0x100000001b3
        }
        hash ^= UInt64(text.utf16.count)
        hash &*= 0x100000001b3
        return hash
    }

    private func invalidateStaleNoteData(noteID: UUID) {
        let removedSpans = spansByNote.removeValue(forKey: noteID) != nil
        let removedCuts = hardCutsByNote.removeValue(forKey: noteID) != nil
        let removedSignature = textSignatureByNote.removeValue(forKey: noteID) != nil
        guard removedSpans || removedCuts || removedSignature else { return }
        save()
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
            if let decoded = try? JSONDecoder().decode(PersistedPayload.self, from: data) {
                spansByNote = decoded.spansByNote
                hardCutsByNote = decoded.hardCutsByNote
                textSignatureByNote = decoded.textSignatureByNote
                // Inter-token spacing is intentionally NOT persisted across installs.
                // Old files may contain spacingByNote; we ignore it on load.
                spacingByNote = [:]
                return
            }
            if let decoded = try? JSONDecoder().decode([UUID: [StoredSpan]].self, from: data) {
                spansByNote = decoded
                hardCutsByNote = [:]
                textSignatureByNote = [:]
                spacingByNote = [:]
                return
            }
            // Backward-compat: older boundary index format existed briefly; ignore it.
            _ = try? JSONDecoder().decode([UUID: [Int]].self, from: data)
            spansByNote = [:]
            hardCutsByNote = [:]
            textSignatureByNote = [:]
            spacingByNote = [:]
        } catch {
            CustomLogger.shared.error("Failed to load token boundaries: \(error)")
            spansByNote = [:]
            hardCutsByNote = [:]
            textSignatureByNote = [:]
            spacingByNote = [:]
        }
    }

    private func save() {
        guard let url = fileURL() else { return }
        do {
            let payload = PersistedPayload(
                spansByNote: spansByNote,
                hardCutsByNote: hardCutsByNote,
                textSignatureByNote: textSignatureByNote
            )
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            CustomLogger.shared.error("Failed to save token boundaries: \(error)")
        }
    }
}

