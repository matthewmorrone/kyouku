import SwiftUI
import Combine
import UniformTypeIdentifiers
import Foundation

final class WordsImportViewModel: ObservableObject {
    @Published var isImportingWords: Bool = false
    @Published var showImportPaste: Bool = false
    @Published var importRawText: String = ""
    @Published var importError: String? = nil
    @Published var importSummary: String? = nil
    @Published var showImportError: Bool = false
    @Published var showImportSummary: Bool = false
    @Published var importPreviewURL: URL? = nil
    @Published var previewItems: [WordsImportPreviewItem] = []
    @Published var showImportPreview: Bool = false
    @Published var preferKanaOnly: Bool = false
    @Published var delimiterSelection: WordsDelimiterChoice = .auto
    
    func handleWordsImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                importError = "No file selected."
                showImportError = true
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                importError = "Failed to access the file."
                showImportError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)
                var text: String? = String(data: data, encoding: .utf8)
                if text == nil {
                    text = String(data: data, encoding: .unicode)
                }
                if text == nil {
                    text = String(data: data, encoding: .ascii)
                }
                if let text = text {
                    self.importRawText = text
                    self.importPreviewURL = url
                    self.showImportPaste = true
                } else {
                    importError = "Could not decode the file contents."
                    showImportError = true
                }
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }
        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }
    
    func reloadPreviewForDelimiter() {
        guard let url = importPreviewURL else {
            previewItems = []
            return
        }
        guard let data = try? Data(contentsOf: url),
              var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) ?? String(data: data, encoding: .ascii) else {
            previewItems = []
            return
        }
        if text.last != "\n" {
            text.append("\n")
        }
        let delimiterToUse: Character?
        switch delimiterSelection {
        case .auto:
            delimiterToUse = bestGuessDelimiter(for: text)
        case .comma:
            delimiterToUse = ","
        case .semicolon:
            delimiterToUse = ";"
        case .tab:
            delimiterToUse = "\t"
        case .pipe:
            delimiterToUse = "|"
        }
        let items = WordsImport.parseItems(fromString: text, delimiter: delimiterToUse)
        updatePreviewItems(from: items)
    }
    
    func updatePreviewItems(from importerItems: [WordsImport.ImportItem]) {
        previewItems = importerItems.map { item in
            WordsImportPreviewItem(
                id: item.id,
                lineNumber: item.lineNumber,
                providedSurface: item.providedSurface,
                providedReading: item.providedReading,
                providedMeaning: item.providedMeaning,
                note: item.note,
                computedSurface: item.computedSurface,
                computedReading: item.computedReading,
                computedMeaning: item.computedMeaning
            )
        }
    }
    
    @MainActor
    func fillMissingForPreviewItems() async {
        var items = previewItems.map { preview -> WordsImport.ImportItem in
            WordsImport.ImportItem(
                lineNumber: preview.lineNumber,
                providedSurface: preview.providedSurface,
                providedReading: preview.providedReading,
                providedMeaning: preview.providedMeaning,
                note: preview.note,
                computedSurface: preview.computedSurface,
                computedReading: preview.computedReading,
                computedMeaning: preview.computedMeaning
            )
        }
        await WordsImport.fillMissing(items: &items, preferKanaOnly: preferKanaOnly)
        updatePreviewItems(from: items)
    }
    
    func finalizePreviewItems() -> [(surface: String, reading: String, meaning: String, note: String?)] {
        let prepared = WordsImport.finalize(items: toImporterItems(previewItems), preferKanaOnly: preferKanaOnly)
        return prepared.map { ($0.surface, $0.reading, $0.meaning, $0.note) }
    }
    
    // MARK: - Private helpers
    
    private func toImporterItems(_ previewItems: [WordsImportPreviewItem]) -> [WordsImport.ImportItem] {
        previewItems.map { preview in
            WordsImport.ImportItem(
                lineNumber: preview.lineNumber,
                providedSurface: preview.providedSurface,
                providedReading: preview.providedReading,
                providedMeaning: preview.providedMeaning,
                note: preview.note,
                computedSurface: preview.computedSurface,
                computedReading: preview.computedReading,
                computedMeaning: preview.computedMeaning
            )
        }
    }
    
    private func bestGuessDelimiter(for text: String) -> Character {
        guard let firstLine = text.components(separatedBy: "\n").first else {
            return ","
        }
        let delimiters: [Character] = [",", ";", "\t", "|"]
        var counts: [Character: Int] = [:]
        
        for delimiter in delimiters {
            counts[delimiter] = firstLine.filter { $0 == delimiter }.count
        }
        let maxCount = counts.values.max() ?? 0
        if maxCount == 0 {
            return ","
        }
        let bestDelimiter = counts.first { $0.value == maxCount }?.key ?? ","
        return bestDelimiter
    }
}

