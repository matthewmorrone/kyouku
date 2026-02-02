import SwiftUI

/// Debug-only overlay that draws a 2D pixel ruler and grid.
///
/// Coordinates are in the overlay’s local coordinate space where (0,0) is the top-left.
/// iOS layout units are points; this view annotates ticks in device pixels via `displayScale`.
struct PixelRulerOverlayView: View {
    @Environment(\.displayScale) private var displayScale

    private let rulerThickness: CGFloat = 22
    private let rulerInset: CGFloat = 0

    // Pixel-based spacing for the grid/ticks.
    private let minorStepPx: Int = 10
    private let majorStepPx: Int = 50
    private let labelStepPx: Int = 100

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let minorStep = CGFloat(minorStepPx) / max(1, displayScale)
            let majorStep = CGFloat(majorStepPx) / max(1, displayScale)
            let labelStep = CGFloat(labelStepPx) / max(1, displayScale)

            Canvas { context, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height

                // Background rulers.
                let topRuler = CGRect(x: 0, y: 0, width: w, height: rulerThickness)
                let leftRuler = CGRect(x: 0, y: 0, width: rulerThickness, height: h)

                context.fill(Path(topRuler), with: .color(.black.opacity(0.28)))
                context.fill(Path(leftRuler), with: .color(.black.opacity(0.28)))

                // Grid lines.
                if minorStep > 0 {
                    var x: CGFloat = rulerThickness + rulerInset
                    while x < w {
                        let isMajor = majorStep > 0 && (abs((x - rulerThickness).truncatingRemainder(dividingBy: majorStep)) < 0.01)
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: rulerThickness))
                        p.addLine(to: CGPoint(x: x, y: h))
                        context.stroke(
                            p,
                            with: .color(isMajor ? .red.opacity(0.35) : .white.opacity(0.14)),
                            lineWidth: isMajor ? 0.75 : 0.5
                        )
                        x += minorStep
                    }

                    var y: CGFloat = rulerThickness + rulerInset
                    while y < h {
                        let isMajor = majorStep > 0 && (abs((y - rulerThickness).truncatingRemainder(dividingBy: majorStep)) < 0.01)
                        var p = Path()
                        p.move(to: CGPoint(x: rulerThickness, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                        context.stroke(
                            p,
                            with: .color(isMajor ? .red.opacity(0.35) : .white.opacity(0.14)),
                            lineWidth: isMajor ? 0.75 : 0.5
                        )
                        y += minorStep
                    }
                }

                let labelFont = Font.system(size: 9, weight: .regular, design: .monospaced)

                // Top ticks + labels.
                if minorStep > 0 {
                    var x: CGFloat = rulerThickness + rulerInset
                    while x < w {
                        let dx = x - rulerThickness
                        let px = Int(round(dx * displayScale))

                        let isMajor = majorStep > 0 && (abs(dx.truncatingRemainder(dividingBy: majorStep)) < 0.01)
                        let isLabel = labelStep > 0 && (abs(dx.truncatingRemainder(dividingBy: labelStep)) < 0.01)

                        let tickHeight: CGFloat = isMajor ? 10 : 6
                        var tick = Path()
                        tick.move(to: CGPoint(x: x, y: 0))
                        tick.addLine(to: CGPoint(x: x, y: tickHeight))
                        context.stroke(tick, with: .color(.white.opacity(isMajor ? 0.75 : 0.35)), lineWidth: 1)

                        if isLabel {
                            let text = Text("\(px)").font(labelFont).foregroundStyle(.white.opacity(0.9))
                            context.draw(text, at: CGPoint(x: x + 2, y: rulerThickness - 10), anchor: .leading)
                        }

                        x += minorStep
                    }
                }

                // Left ticks + labels.
                if minorStep > 0 {
                    var y: CGFloat = rulerThickness + rulerInset
                    while y < h {
                        let dy = y - rulerThickness
                        let px = Int(round(dy * displayScale))

                        let isMajor = majorStep > 0 && (abs(dy.truncatingRemainder(dividingBy: majorStep)) < 0.01)
                        let isLabel = labelStep > 0 && (abs(dy.truncatingRemainder(dividingBy: labelStep)) < 0.01)

                        let tickWidth: CGFloat = isMajor ? 10 : 6
                        var tick = Path()
                        tick.move(to: CGPoint(x: 0, y: y))
                        tick.addLine(to: CGPoint(x: tickWidth, y: y))
                        context.stroke(tick, with: .color(.white.opacity(isMajor ? 0.75 : 0.35)), lineWidth: 1)

                        if isLabel {
                            let text = Text("\(px)").font(labelFont).foregroundStyle(.white.opacity(0.9))
                            context.draw(text, at: CGPoint(x: rulerThickness - 2, y: y + 2), anchor: .trailing)
                        }

                        y += minorStep
                    }
                }

                // Corner legend.
                let pxW = Int(round(size.width * displayScale))
                let pxH = Int(round(size.height * displayScale))
                let legend = Text("scale \(String(format: "%.0fx", displayScale))\n\(Int(size.width))×\(Int(size.height)) pt\n\(pxW)×\(pxH) px")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                context.draw(legend, at: CGPoint(x: rulerThickness + 6, y: rulerThickness + 6), anchor: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
