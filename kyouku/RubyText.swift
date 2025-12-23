import SwiftUI
import UIKit

struct RubyText: UIViewRepresentable {
    var attributed: NSAttributedString
    var fontSize: CGFloat
    var lineHeightMultiple: CGFloat
    var extraGap: CGFloat

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.textColor = .label
        label.font = UIFont.systemFont(ofSize: fontSize)
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.textColor = .label

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = max(0.8, lineHeightMultiple)
        paragraph.lineSpacing = max(0, extraGap)
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        uiView.attributedText = mutable
    }
}
