import SwiftUI
import UIKit
import Foundation

extension PasteView {
    var inlineDismissScrim: some View {
        // When the inline dictionary panel is visible, we used to dim the background.
        // That can read as a “faint highlight” across non-selected tokens, so keep it clear.
        // IMPORTANT: keep this scrim non-interactive so it never blocks scrolling.
        Color.clear
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .transition(.opacity)
            .zIndex(0.5)
    }
}
