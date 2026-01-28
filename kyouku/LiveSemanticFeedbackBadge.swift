import SwiftUI

struct LiveSemanticFeedbackBadge: View {
    let feedback: PasteView.LiveSemanticFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = feedback.previousSimilarity {
                row(label: "Prev", sim: p)
            }
            if let p = feedback.paragraphSimilarity {
                row(label: "Para", sim: p)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appBorder, lineWidth: 1)
        )
    }

    private func row(label: String, sim: Float) -> some View {
        let value01 = clamp01((sim + 1) * 0.5)
        let percent = Int((value01 * 100).rounded())
        let tint = color(for: value01)

        return HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.appTextSecondary)
                .frame(width: 34, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.appSoftFill)
                    RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.75))
                        .frame(width: max(2, proxy.size.width * CGFloat(value01)))
                }
            }
            .frame(height: 8)

            Text("\(percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func clamp01(_ x: Float) -> Float {
        max(0, min(1, x))
    }

    private func color(for value01: Float) -> Color {
        // Red (0) -> Yellow (0.5) -> Green (1)
        let v = Double(clamp01(value01))
        if v < 0.5 {
            let t = v / 0.5
            return lerp(Color.red, Color.yellow, t: t)
        } else {
            let t = (v - 0.5) / 0.5
            return lerp(Color.yellow, Color.green, t: t)
        }
    }

    private func lerp(_ a: Color, _ b: Color, t: Double) -> Color {
        // Use UIColor interpolation for stability.
        let ua = UIColor(a)
        let ub = UIColor(b)

        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        ua.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        ub.getRed(&br, green: &bg, blue: &bb, alpha: &ba)

        let u = CGFloat(max(0, min(1, t)))
        return Color(
            UIColor(
                red: ar + (br - ar) * u,
                green: ag + (bg - ag) * u,
                blue: ab + (bb - ab) * u,
                alpha: 1
            )
        )
    }
}
