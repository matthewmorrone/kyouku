import Foundation

struct DictionaryEntryDetail: Identifiable, Hashable {
    let entryID: Int64
    let isCommon: Bool
    let kanjiForms: [DictionaryEntryForm]
    let kanaForms: [DictionaryEntryForm]
    let senses: [DictionaryEntrySense]

    var id: Int64 { entryID }
}
