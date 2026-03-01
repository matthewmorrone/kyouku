import SwiftUI

enum DictionaryPartOfSpeech: String, CaseIterable, Hashable, Identifiable {
    case noun
    case verb
    case adjective
    case adverb
    case expression
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noun: return "Noun"
        case .verb: return "Verb"
        case .adjective: return "Adjective"
        case .adverb: return "Adverb"
        case .expression: return "Expression"
        case .other: return "Other"
        }
    }

    static func fromJMdictTag(_ raw: String) -> DictionaryPartOfSpeech? {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard tag.isEmpty == false else { return nil }
        if tag.hasPrefix("v") { return .verb }
        if tag.hasPrefix("adj") { return .adjective }
        if tag.hasPrefix("adv") { return .adverb }
        if tag.hasPrefix("n") || tag == "pn" { return .noun }
        if tag.hasPrefix("exp") { return .expression }
        return nil
    }
}

enum DictionaryJLPTLevel: String, CaseIterable, Hashable, Identifiable {
    case n1
    case n2
    case n3
    case n4
    case n5

    var id: String { rawValue }

    func matches(filter: SearchViewModel.JLPTFilter) -> Bool {
        switch filter {
        case .any: return true
        case .n1: return self == .n1
        case .n2: return self == .n2
        case .n3: return self == .n3
        case .n4: return self == .n4
        case .n5: return self == .n5
        }
    }

    static func fromTag(_ raw: String) -> DictionaryJLPTLevel? {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard tag.hasPrefix("jlpt") else { return nil }
        guard let suffix = tag.last, let level = Int(String(suffix)) else { return nil }
        switch level {
        case 1: return .n1
        case 2: return .n2
        case 3: return .n3
        case 4: return .n4
        case 5: return .n5
        default: return nil
        }
    }
}

/// Lightweight view model for a merged dictionary result row.
struct DictionaryResultRow: Identifiable {
    let entryID: Int64
    let surface: String
    let kana: String?
    let gloss: String
    let isCommon: Bool
    let partsOfSpeech: Set<DictionaryPartOfSpeech>
    let jlptLevel: DictionaryJLPTLevel?

    var id: String { "\(surface)#\(kana ?? "(no-kana)")" }

    struct Builder {
        let surface: String
        let kanaKey: String
        var entries: [DictionaryEntry]

        func build(
            firstGlossFor: (DictionaryEntry) -> String,
            detailForEntryID: (Int64) -> DictionaryEntryDetail?
        ) -> DictionaryResultRow? {
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

            var inferredPartsOfSpeech: Set<DictionaryPartOfSpeech> = []
            var inferredJLPTLevels: Set<DictionaryJLPTLevel> = []

            for entry in entries {
                guard let detail = detailForEntryID(entry.entryID) else { continue }

                for sense in detail.senses {
                    for tag in sense.partsOfSpeech {
                        if let mapped = DictionaryPartOfSpeech.fromJMdictTag(tag) {
                            inferredPartsOfSpeech.insert(mapped)
                        }
                    }
                }

                for tag in detail.kanjiForms.flatMap(\.tags) + detail.kanaForms.flatMap(\.tags) {
                    if let level = DictionaryJLPTLevel.fromTag(tag) {
                        inferredJLPTLevels.insert(level)
                    }
                }
            }

            let gloss = firstGlossFor(first)
            return DictionaryResultRow(
                entryID: first.entryID,
                surface: surface,
                kana: displayKana,
                gloss: gloss,
                isCommon: first.isCommon,
                partsOfSpeech: inferredPartsOfSpeech,
                jlptLevel: inferredJLPTLevels.sorted { $0.rawValue < $1.rawValue }.first
            )
        }
    }
}

extension EditMode {
    var isEditing: Bool {
        self != .inactive
    }
}
