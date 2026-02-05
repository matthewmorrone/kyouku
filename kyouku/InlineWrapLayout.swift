import SwiftUI

/// A simple flow layout that places subviews left-to-right and wraps to new lines.
///
/// Used for rendering mixed text + inline controls (e.g. cloze dropdowns) while
/// preserving wrapping behavior.
@available(iOS 16.0, *)
struct InlineWrapLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 6

    private struct LineItem {
        let subviewIndex: Int
        let size: CGSize
        let firstBaseline: CGFloat
    }

    private struct Line {
        var items: [LineItem] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0

        var height: CGFloat { ascent + descent }
    }

    private func firstBaseline(for subview: LayoutSubview, size: CGSize) -> CGFloat {
        let dims = subview.dimensions(in: ProposedViewSize.unspecified)
        let baseline = dims[VerticalAlignment.firstTextBaseline]
        if baseline.isFinite, baseline > 0, baseline <= size.height {
            return baseline
        }
        // For non-text views, SwiftUI often reports the baseline at the bottom.
        // If we get something unusable, fall back to bottom alignment.
        return size.height
    }

    private func computeLines(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        lines.reserveCapacity(8)

        var current = Line()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize.unspecified)
            let baseline = firstBaseline(for: subview, size: size)

            let itemWidth = (current.items.isEmpty ? 0 : spacing) + size.width
            if current.items.isEmpty == false, current.width + itemWidth > maxWidth {
                lines.append(current)
                current = Line()
            }

            if current.items.isEmpty == false {
                current.width += spacing
            }
            current.items.append(LineItem(subviewIndex: index, size: size, firstBaseline: baseline))
            current.width += size.width
            current.ascent = max(current.ascent, baseline)
            current.descent = max(current.descent, size.height - baseline)
        }

        if current.items.isEmpty == false {
            lines.append(current)
        }

        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320

        let lines = computeLines(maxWidth: maxWidth, subviews: subviews)
        let usedWidth = lines.map(\.width).max() ?? 0
        let totalHeight = lines.enumerated().reduce(CGFloat(0)) { acc, element in
            let (idx, line) = element
            return acc + line.height + (idx == 0 ? 0 : lineSpacing)
        }

        return CGSize(width: min(usedWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let lines = computeLines(maxWidth: maxWidth, subviews: subviews)

        var y = bounds.minY
        for (lineIndex, line) in lines.enumerated() {
            var x = bounds.minX
            for item in line.items {
                let dy = line.ascent - item.firstBaseline
                subviews[item.subviewIndex].place(
                    at: CGPoint(x: x, y: y + dy),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )

                x += item.size.width
                if item.subviewIndex != line.items.last?.subviewIndex {
                    x += spacing
                }
            }

            y += line.height
            if lineIndex != lines.count - 1 {
                y += lineSpacing
            }
        }
    }
}
