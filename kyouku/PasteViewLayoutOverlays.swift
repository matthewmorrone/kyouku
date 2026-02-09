import SwiftUI
import UIKit
import Foundation

extension PasteView {
    @ViewBuilder
    var tokenGeometryDebugOverlay: some View {
        GeometryReader { proxy in
            ZStack {
                // Outline the coordinate-space container itself.
                Rectangle()
                    .stroke(Color.yellow.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .position(x: proxy.size.width / 2.0, y: proxy.size.height / 2.0)

                // Mark the coordinate-space origin.
                Circle()
                    .fill(Color.yellow.opacity(0.9))
                    .frame(width: 6, height: 6)
                    .position(x: 0, y: 0)

                if let paste = pasteAreaFrame {
                    Rectangle()
                        .fill(Color.cyan.opacity(0.06))
                        .frame(width: paste.width, height: paste.height)
                        .position(x: paste.midX, y: paste.midY)

                    Rectangle()
                        .stroke(
                            Color.cyan.opacity(0.95),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [14, 10])
                        )
                        .frame(width: paste.width, height: paste.height)
                        .position(x: paste.midX, y: paste.midY)
                }

                if let panel = tokenPanelFrame {
                    Rectangle()
                        .stroke(Color.red.opacity(0.9), lineWidth: 2)
                        .frame(width: panel.width, height: panel.height)
                        .position(x: panel.midX, y: panel.midY)
                }
            }
            .allowsHitTesting(false)
        }
    }

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
