import Foundation

struct ExampleSentence: Identifiable, Hashable {
    let jpID: Int64
    let enID: Int64
    let jpText: String
    let enText: String

    var id: String { "\(jpID)#\(enID)" }
}
