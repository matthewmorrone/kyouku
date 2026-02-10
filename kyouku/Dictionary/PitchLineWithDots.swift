import SwiftUI

struct PitchLineWithDots: View {
    let levels: [Bool]
    let visualScale: CGFloat

    var body: some View {
        GeometryReader { geo in
            let scale = max(1, visualScale)
            let w = max(1, geo.size.width)
            let n = max(2, levels.count)

            // Place the line just above the text.
            let yHigh: CGFloat = 2 * scale
            let yLow: CGFloat = 10 * scale

            let denom = CGFloat(max(1, n - 1))
            let points: [CGPoint] = levels.enumerated().map { idx, isHigh in
                let x = w * CGFloat(idx) / denom
                let y = isHigh ? yHigh : yLow
                return CGPoint(x: x, y: y)
            }

            ZStack(alignment: .topLeading) {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() {
                        p.addLine(to: pt)
                    }
                }
                .stroke(
                    Color.accentColor.opacity(0.9),
                    style: StrokeStyle(
                        lineWidth: 2 * scale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

                let dotDiameter: CGFloat = 4.5 * scale
                ForEach(Array(points.enumerated()), id: \.offset) { _, pt in
                    Circle()
                        .fill(Color.accentColor.opacity(0.95))
                        .frame(width: dotDiameter, height: dotDiameter)
                        .position(x: pt.x, y: pt.y)
                }
            }
        }
        .frame(height: 14 * max(1, visualScale))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

