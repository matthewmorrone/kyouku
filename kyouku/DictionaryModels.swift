import Foundation

struct DictionaryEntryForm: Identifiable, Hashable {
    let id: Int64
    let text: String
    let isCommon: Bool
    let tags: [String]
}

struct DictionarySenseGloss: Identifiable, Hashable {
    let id: Int64
    let text: String
    let language: String
    let orderIndex: Int
}

struct DictionaryEntrySense: Identifiable, Hashable {
    let id: Int64
    let orderIndex: Int
    let partsOfSpeech: [String]
    let miscellaneous: [String]
    let fields: [String]
    let dialects: [String]
    let glosses: [DictionarySenseGloss]
}

struct DictionaryEntryDetail: Identifiable, Hashable {
    let entryID: Int64
    let isCommon: Bool
    let kanjiForms: [DictionaryEntryForm]
    let kanaForms: [DictionaryEntryForm]
    let senses: [DictionaryEntrySense]

    var id: Int64 { entryID }
}

struct ExampleSentence: Identifiable, Hashable {
    let jpID: Int64
    let enID: Int64
    let jpText: String
    let enText: String

    var id: String { "\(jpID)#\(enID)" }
}

struct PitchAccent: Identifiable, Hashable, Sendable {
    let surface: String
    let reading: String
    let accent: Int
    let morae: Int
    let kind: String?
    let readingMarked: String?

    var id: String {
        let k = kind ?? ""
        let rm = readingMarked ?? ""
        return "\(surface)#\(reading)#\(accent)#\(morae)#\(k)#\(rm)"
    }
}

struct SurfaceReadingOverride: Hashable, Sendable {
    let surface: String
    let reading: String
}



enum DictionarySearchMode {
    case japanese
    case english
}
