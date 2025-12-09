import Foundation

struct ParsedToken: Identifiable, Hashable {
    let id = UUID()
    var surface: String
    var reading: String
    var meaning: String?
}
