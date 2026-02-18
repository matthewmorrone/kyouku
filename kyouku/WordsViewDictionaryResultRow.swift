import SwiftUI

/// Lightweight view model for a merged dictionary result row.
struct DictionaryResultRow: Identifiable {
    let surface: String
    let kana: String?
    let gloss: String
    let isCommon: Bool

    var id: String { "\(surface)#\(kana ?? "(no-kana)")" }

    struct Builder {
        let surface: String
        let kanaKey: String
        var entries: [DictionaryEntry]

        func build(firstGlossFor: (DictionaryEntry) -> String) -> DictionaryResultRow? {
            guard let first = entries.first else { return nil }
            let allKana: [String] = entries.compactMap { $0.kana?.trimmingCharacters(in: .whitespacesAndNewlines) }
            let displayKana: String? = {
                let cleaned = allKana.filter { $0.isEmpty == false }
                guard cleaned.isEmpty == false else { return nil }

                func isAllHiragana(_ text: String) -> Bool {
                    guard text.isEmpty == false else { return false }
                    return text.unicodeScalars.allSatisfy { (0x3040...0x309F).contains($0.value) }
                }

                if let hira = cleaned.first(where: isAllHiragana) { return hira }
                return cleaned.first
            }()

            let gloss = firstGlossFor(first)
            return DictionaryResultRow(surface: surface, kana: displayKana, gloss: gloss, isCommon: first.isCommon)
        }
    }
}

extension EditMode {
    var isEditing: Bool {
        self != .inactive
    }
}
