import Foundation

struct DictionaryEntrySense: Identifiable, Hashable {
    let id: Int64
    let orderIndex: Int
    let partsOfSpeech: [String]
    let miscellaneous: [String]
    let fields: [String]
    let dialects: [String]
    let glosses: [DictionarySenseGloss]
}
