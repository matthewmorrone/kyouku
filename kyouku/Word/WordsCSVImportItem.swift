import SwiftUI
import UniformTypeIdentifiers

struct WordsCSVImportItem: Identifiable, Hashable {
    let id: UUID
    let lineNumber: Int

    var providedSurface: String?
    var providedKana: String?
    var providedMeaning: String?
    var providedNote: String?

    var computedSurface: String?
    var computedKana: String?
    var computedMeaning: String?

    init(
        id: UUID = UUID(),
        lineNumber: Int,
        providedSurface: String?,
        providedKana: String?,
        providedMeaning: String?,
        providedNote: String?
    ) {
        self.id = id
        self.lineNumber = lineNumber
        self.providedSurface = providedSurface
        self.providedKana = providedKana
        self.providedMeaning = providedMeaning
        self.providedNote = providedNote
    }

    var finalSurface: String? {
        let raw = (providedSurface ?? computedSurface)
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var finalKana: String? {
        let raw = (providedKana ?? computedKana)
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var finalMeaning: String? {
        let raw = (providedMeaning ?? computedMeaning)
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var finalNote: String? {
        guard let raw = providedNote else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

