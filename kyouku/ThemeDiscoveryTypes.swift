import Foundation

struct ThemeCluster: Identifiable, Hashable {
    let id: String
    var label: String
    var noteIDs: [UUID]
    var noteCount: Int { noteIDs.count }

    // Diagnostics / sorting
    var hasEmbedding: Bool
}

struct ThemeNoteEmbeddingSnapshot: Hashable {
    let noteID: UUID
    let signature: Int
    let centroid: [Float]?
    let topTerms: [String: Int]
}

struct ThemeDiscoveryState: Hashable {
    var clusters: [ThemeCluster] = []
    var lastUpdatedAt: Date? = nil
    var isComputing: Bool = false
}
