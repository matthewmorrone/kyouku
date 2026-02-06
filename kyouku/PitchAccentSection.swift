import SwiftUI

/// Renders a simple Tokyo-style pitch pattern as a dotted polyline above the reading.
///
/// - Note: This is a visualization aid, not a phonology engine. It assumes the DB's
///   `accent` is the downstep position (0 = heiban) and `morae` is the unit count.
struct PitchAccentSection: View {
    let headword: String
    let reading: String
    let accents: [PitchAccent]
    var showsTitle: Bool = true
    var visualScale: CGFloat = 1

    var body: some View {
        let scale = max(1, visualScale)

        VStack(alignment: .leading, spacing: 4 * scale) {
            if showsTitle {
                HStack(spacing: 8 * scale) {
                    Text("Pitch Accent")
                        .font(.system(size: 13 * scale, weight: .semibold))
                    Spacer(minLength: 0)
                }
            }

            SwiftUI.ForEach(accents, id: \PitchAccent.id) { (accent: PitchAccent) in
                let displayReading = accent.readingMarked?.replacingOccurrences(of: "◦", with: "") ?? reading
                let pattern = PitchPattern.levels(morae: max(1, accent.morae), accent: accent.accent)

                HStack(alignment: .top, spacing: 4 * scale) {
                    PitchMarkedText(text: displayReading, levels: pattern, visualScale: scale)

                    HStack(spacing: 10 * scale) {
                        // Text("accent: \(accent.accent)/\(accent.morae)")
                        if let kind = accent.kind, kind.isEmpty == false {
                            Text("\(kind)")
                        }
                    }
                    .font(.system(size: 4 * scale, weight: .regular))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pitch accent")
        .accessibilityValue("\(headword), \(reading)")
    }
}

private enum PitchPattern {
    /// Returns a per-mora high/low pattern.
    ///
    /// Convention used:
    /// - accent=0 (heiban): low → high and stays high
    /// - accent=1 (atamadaka): high then low
    /// - accent=k (2..morae): low, rise after first, drop after k
    static func levels(morae: Int, accent: Int) -> [Bool] {
        let n = max(1, morae)
        let a = max(0, min(accent, n))

        // true = high, false = low
        if n == 1 {
            return [a == 1]
        }

        if a == 0 {
            // L H H H...
            return [false] + Array(repeating: true, count: n - 1)
        }

        if a == 1 {
            // H L L L...
            return [true] + Array(repeating: false, count: n - 1)
        }

        // a in 2...n
        // L (H ... H) (L ... L)
        // indices: 0 low, 1..a-1 high, a..n-1 low
        var out: [Bool] = Array(repeating: false, count: n)
        out[0] = false
        for idx in 1..<n {
            out[idx] = idx < a
        }
        return out
    }
}

private struct PitchMarkedText: View {
    let text: String
    let levels: [Bool]
    let visualScale: CGFloat

    var body: some View {
        let scale = max(1, visualScale)
        let lineHeight: CGFloat = 14 * scale
        let clearGap: CGFloat = 6 * scale
        Text(text)
            .font(.system(size: 15 * scale, weight: .regular))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    PitchLineWithDots(levels: levels, visualScale: scale)
                        .frame(width: geo.size.width, height: lineHeight, alignment: .topLeading)
                        .offset(y: -(lineHeight + clearGap))
                }
            }
            .padding(.top, lineHeight + clearGap)
    }
}

private struct PitchLineWithDots: View {
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
