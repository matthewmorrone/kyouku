import SwiftUI
import Combine

enum AppTab: Hashable {
    case paste
    case notes
    case dictionary
    case cards
    case settings
}

final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .paste
    @Published var noteToOpen: Note? = nil
    @Published var pasteShouldBeginEditing: Bool = false
    @Published var pendingResetNoteID: UUID? = nil

    struct OpenWordRequest: Identifiable, Equatable {
        let id: UUID = UUID()
        let wordID: UUID
    }

    @Published var openWordRequest: OpenWordRequest? = nil

    func openWordDetails(wordID: UUID) {
        selectedTab = .dictionary
        openWordRequest = OpenWordRequest(wordID: wordID)
    }
}

