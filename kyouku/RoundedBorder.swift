import SwiftUI

struct RoundedBorderModifier: ViewModifier {
    let color: Color
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let style: RoundedCornerStyle
    let clip: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: style)
        content
            .overlay(shape.stroke(color, lineWidth: lineWidth))
            .applyIf(clip) { view in
                view.clipShape(shape)
            }
    }
}

extension View {
    /// Applies a rounded rectangle border using overlay. Optionally clips the content to the same shape.
    func roundedBorder(
        _ color: Color,
        cornerRadius: CGFloat,
        lineWidth: CGFloat = 1,
        style: RoundedCornerStyle = .continuous,
        clip: Bool = false
    ) -> some View {
        modifier(RoundedBorderModifier(
            color: color,
            cornerRadius: cornerRadius,
            lineWidth: lineWidth,
            style: style,
            clip: clip
        ))
    }
}

private extension View {
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
