import Foundation

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
