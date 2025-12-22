import SwiftUI
import Combine

enum AppTab: Hashable {
    case paste
    case notes
    case cards
    case words
    case settings
}

final class AppRouter: ObservableObject {
    @Published var selectedTab: AppTab = .paste
    @Published var noteToOpen: Note? = nil
}

