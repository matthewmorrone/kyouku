import Foundation

struct DictionaryEntryForm: Identifiable, Hashable {
    let id: Int64
    let text: String
    let isCommon: Bool
    let tags: [String]
}
