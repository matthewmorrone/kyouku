import Foundation

enum WordsFilter: Hashable {
    case all
    case list(UUID)
    case note(UUID)

    var isAll: Bool {
        switch self {
        case .all: return true
        case .list, .note: return false
        }
    }
}
