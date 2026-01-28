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
	}

	@Published private(set) var spansByNote: [UUID: [StoredSpan]] = [:]
	@Published private(set) var hardCutsByNote: [UUID: [Int]] = [:]

	private let fileName = "token-spans.json"

	init() {
		load()
	}

	func hasCustomSpans(for noteID: UUID) -> Bool {
		(spansByNote[noteID]?.isEmpty == false)
	}

	func hasHardCuts(for noteID: UUID) -> Bool {
		(hardCutsByNote[noteID]?.isEmpty == false)
	}

	func hardCuts(for noteID: UUID, text: String) -> [Int] {
		guard let cuts = hardCutsByNote[noteID], cuts.isEmpty == false else { return [] }
		let length = (text as NSString).length
		guard length > 0 else { return [] }
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
		save()
	}

	func removeHardCut(noteID: UUID, utf16Index: Int) {
		guard var cuts = hardCutsByNote[noteID], cuts.isEmpty == false else { return }
		let before = cuts.count
		cuts.removeAll { $0 == utf16Index }
		guard cuts.count != before else { return }
		hardCutsByNote[noteID] = cuts.isEmpty ? nil : cuts
		save()
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

	func restoreHardCuts(noteID: UUID, cuts: [Int]?) {
		if let cuts, cuts.isEmpty == false {
			hardCutsByNote[noteID] = cuts
		} else {
			hardCutsByNote[noteID] = nil
		}
		save()
	}

	func spans(for noteID: UUID, text: String) -> [TextSpan]? {
		guard let stored = spansByNote[noteID], stored.isEmpty == false else { return nil }
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
		save()
	}

	func removeAll(for noteID: UUID) {
		let removedSpans = spansByNote.removeValue(forKey: noteID) != nil
		let removedCuts = hardCutsByNote.removeValue(forKey: noteID) != nil
		guard removedSpans || removedCuts else { return }
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
				return
			}
			if let decoded = try? JSONDecoder().decode([UUID: [StoredSpan]].self, from: data) {
				spansByNote = decoded
				hardCutsByNote = [:]
				return
			}
			// Backward-compat: older boundary index format existed briefly; ignore it.
			_ = try? JSONDecoder().decode([UUID: [Int]].self, from: data)
			spansByNote = [:]
			hardCutsByNote = [:]
		} catch {
			CustomLogger.shared.error("Failed to load token boundaries: \(error)")
			spansByNote = [:]
			hardCutsByNote = [:]
		}
	}

	private func save() {
		guard let url = fileURL() else { return }
		do {
			let payload = PersistedPayload(spansByNote: spansByNote, hardCutsByNote: hardCutsByNote)
			let data = try JSONEncoder().encode(payload)
			try data.write(to: url, options: .atomic)
		} catch {
			CustomLogger.shared.error("Failed to save token boundaries: \(error)")
		}
	}
}

