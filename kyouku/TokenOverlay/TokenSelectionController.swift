import Combine
import CoreGraphics
import Foundation
import SwiftUI

final class TokenSelectionController: ObservableObject {
    @Published var tokenSelection: TokenSelectionContext? = nil
    @Published var persistentSelectionRange: NSRange? = nil
    @Published var sheetSelection: TokenSelectionContext? = nil
    @Published var sheetPanelHeight: CGFloat = 0
    @Published var pendingSelectionRange: NSRange? = nil
    @Published var pendingSplitFocusSelectionID: String? = nil
    @Published var tokenPanelFrame: CGRect? = nil

    func clearSelection(resetPersistent: Bool) {
        if resetPersistent {
            persistentSelectionRange = nil
        }
        tokenSelection = nil
        sheetSelection = nil
        sheetPanelHeight = 0
        pendingSelectionRange = nil
        pendingSplitFocusSelectionID = nil
        tokenPanelFrame = nil
    }
}
