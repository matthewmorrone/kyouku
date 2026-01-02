import Foundation
import Combine
import OSLog

@MainActor
final class TokenBoundariesStore: ObservableObject {
	struct StoredSpan: Codable, Hashable {
		let start: Int
		let length: Int
		let isLexiconMatch: Bool
	}

	@Published private(set) var spansByNote: [UUID: [StoredSpan]] = [:]

	private static let logger = DiagnosticsLogging.logger(.tokenBoundaries)
	private let fileName = "token-spans.json"

	init() {
		load()
	}

	func hasCustomSpans(for noteID: UUID) -> Bool {
		(spansByNote[noteID]?.isEmpty == false)
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
		Self.logger.debug("Saved amended spans note=\(noteID) count=\(cleaned.count)")
	}

	func removeAll(for noteID: UUID) {
		guard spansByNote.removeValue(forKey: noteID) != nil else { return }
		save()
		Self.logger.debug("Removed amended spans note=\(noteID)")
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
			if let decoded = try? JSONDecoder().decode([UUID: [StoredSpan]].self, from: data) {
				spansByNote = decoded
				Self.logger.debug("Loaded token spans notes=\(self.spansByNote.count)")
				return
			}
			// Backward-compat: older boundary index format existed briefly; ignore it.
			_ = try? JSONDecoder().decode([UUID: [Int]].self, from: data)
			spansByNote = [:]
			Self.logger.debug("Loaded legacy token boundaries format; ignored")
		} catch {
			Self.logger.error("Failed to load token boundaries: \(error.localizedDescription, privacy: .public)")
			spansByNote = [:]
		}
	}

	private func save() {
		guard let url = fileURL() else { return }
		do {
			let data = try JSONEncoder().encode(spansByNote)
			try data.write(to: url, options: .atomic)
			Self.logger.debug("Saved token spans notes=\(self.spansByNote.count)")
		} catch {
			Self.logger.error("Failed to save token boundaries: \(error.localizedDescription, privacy: .public)")
		}
	}
}

