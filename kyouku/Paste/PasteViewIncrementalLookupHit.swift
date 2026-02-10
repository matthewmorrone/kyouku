import Foundation

struct IncrementalLookupHit: Identifiable, Hashable {
    let matchedSurface: String
    let entry: DictionaryEntry

    var id: String { "\(matchedSurface)#\(entry.id)" }
}
