import Foundation

extension WordsView {
    enum DictionaryHomeShelf: String, CaseIterable, Identifiable {
        case favorites
        case history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .favorites: return "Favorites"
            case .history: return "History"
            }
        }
    }

    struct EditingWord: Identifiable {
        let id: Word.ID
    }

    struct SurfaceKanaKey: Hashable {
        let surface: String
        let kana: String
    }
}
