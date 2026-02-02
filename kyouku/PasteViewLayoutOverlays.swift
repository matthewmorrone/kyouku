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

    @ViewBuilder
    var legacyDismissOverlay: some View {
        if #available(iOS 17.0, *) {
            EmptyView()
        }
        else {
            GeometryReader { proxy in
                let containerFrame = proxy.frame(in: .named(Self.coordinateSpaceName))
                let localPaste: CGRect? = pasteAreaFrame.map { paste in
                    CGRect(
                        x: paste.minX - containerFrame.minX,
                        y: paste.minY - containerFrame.minY,
                        width: paste.width,
                        height: paste.height
                    )
                }
                let regions = legacyDismissHitRegions(containerSize: proxy.size, localPaste: localPaste)

                ZStack {
                    ForEach(Array(regions.enumerated()), id: \.offset) { _, rect in
                        // IMPORTANT: UIKit ignores views with alpha <= 0.01 for hit-testing.
                        Color.black.opacity(0.02)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                clearSelection(resetPersistent: false)
                            }
                    }
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
            .zIndex(0.5)
        }
    }

    private func legacyDismissHitRegions(containerSize: CGSize, localPaste: CGRect?) -> [CGRect] {
        let container = CGRect(origin: .zero, size: containerSize)
        guard let paste = localPaste?.intersection(container),
              paste.isNull == false,
              paste.isEmpty == false else {
            return container.size.width > 0 && container.size.height > 0 ? [container] : []
        }

        var regions: [CGRect] = []

        if paste.minY > container.minY {
            let height = paste.minY - container.minY
            regions.append(CGRect(x: container.minX, y: container.minY, width: container.width, height: height))
        }
        if paste.maxY < container.maxY {
            let height = container.maxY - paste.maxY
            regions.append(CGRect(x: container.minX, y: paste.maxY, width: container.width, height: height))
        }
        if paste.minX > container.minX {
            let width = paste.minX - container.minX
            regions.append(CGRect(x: container.minX, y: paste.minY, width: width, height: paste.height))
        }
        if paste.maxX < container.maxX {
            let width = container.maxX - paste.maxX
            regions.append(CGRect(x: paste.maxX, y: paste.minY, width: width, height: paste.height))
        }

        return regions.filter { $0.width > 1 && $0.height > 1 }
    }
}
