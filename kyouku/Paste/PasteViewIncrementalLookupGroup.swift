import Foundation

struct IncrementalLookupGroup: Identifiable, Hashable {
    let matchedSurface: String
    let pages: [IncrementalLookupCollapsed]

    var id: String { matchedSurface }
}
