import SwiftUI

struct PitchMarkedText: View {
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

