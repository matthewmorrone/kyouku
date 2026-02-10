import SwiftUI
import UIKit

struct FuriganaOptionsPopover: View {
    @Binding var wrapLines: Bool
    @Binding var alternateTokenColors: Bool
    @Binding var highlightUnknownTokens: Bool
    @Binding var padHeadwords: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $wrapLines) {
                Label("Wrap Lines", systemImage: "text.append") //point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath.fill
            }
            Toggle(isOn: $padHeadwords) {
                Label("Pad headwords", systemImage: "arrow.left.and.right.text.vertical")
            }
            Toggle(isOn: $alternateTokenColors) {
                Label("Alternate Token Colors", systemImage: "sparkle.text.clipboard")
            }
            Toggle(isOn: $highlightUnknownTokens) {
                Label("Highlight Unknown Words", systemImage: "questionmark.square.dashed")
            }
        }
        .toggleStyle(.switch)
        .padding(14)
        .frame(maxWidth: 320)
    }
}

