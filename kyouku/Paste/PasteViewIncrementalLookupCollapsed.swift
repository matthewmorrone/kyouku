import Foundation

struct IncrementalLookupCollapsed: Identifiable, Hashable {
    let matchedSurface: String
    let kanji: String
    let gloss: String
    let kanaList: String?
    let entries: [DictionaryEntry]

    var id: String {
        let k = kanji.isEmpty ? "(no-kanji)" : kanji
        return "\(matchedSurface)#\(k)#\(gloss)"
    }
}
