import Foundation

struct WordsImportPreviewItem: Identifiable, Hashable {
    let id: UUID
    let lineNumber: Int
    var providedSurface: String?
    var providedReading: String?
    var providedMeaning: String?
    var note: String?
    var computedSurface: String?
    var computedReading: String?
    var computedMeaning: String?

    init(id: UUID = UUID(), lineNumber: Int, providedSurface: String?, providedReading: String?, providedMeaning: String?, note: String?, computedSurface: String?, computedReading: String?, computedMeaning: String?) {
        self.id = id
        self.lineNumber = lineNumber
        self.providedSurface = providedSurface
        self.providedReading = providedReading
        self.providedMeaning = providedMeaning
        self.note = note
        self.computedSurface = computedSurface
        self.computedReading = computedReading
        self.computedMeaning = computedMeaning
    }
}
