import SwiftUI

/// A simple flow layout that places subviews left-to-right and wraps to new lines.
///
/// Used for rendering mixed text + inline controls (e.g. cloze dropdowns) while
/// preserving wrapping behavior.
@available(iOS 16.0, *)
struct InlineWrapLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                // wrap
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }

            x += (x == 0 ? 0 : spacing) + size.width
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x)
        }

        return CGSize(width: min(usedWidth, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }

            if x > bounds.minX {
                x += spacing
            }

            view.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )

            x += size.width
            lineHeight = max(lineHeight, size.height)
        }
    }
}
