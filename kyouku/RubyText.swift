import SwiftUI
import UIKit

struct RubyText: UIViewRepresentable {
    var attributed: NSAttributedString
    var fontSize: CGFloat
    var lineHeightMultiple: CGFloat
    var extraGap: CGFloat
    var textInsets: UIEdgeInsets = RubyText.defaultInsets

    private static let defaultInsets = UIEdgeInsets(top: 10, left: 10, bottom: 6, right: 10)

    func makeUIView(context: Context) -> PaddingLabel {
        let label = PaddingLabel()
        label.textInsets = textInsets
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.textColor = .label
        label.font = UIFont.systemFont(ofSize: fontSize)
        return label
    }

    func updateUIView(_ uiView: PaddingLabel, context: Context) {
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.textColor = .label
        uiView.textInsets = textInsets

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

typealias PaddingLabel = InsetLabel

final class InsetLabel: UILabel {
    var textInsets: UIEdgeInsets = .zero {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetBounds = bounds.inset(by: textInsets)
        let textRect = super.textRect(forBounds: insetBounds, limitedToNumberOfLines: numberOfLines)
        return CGRect(
            x: textRect.origin.x - textInsets.left,
            y: textRect.origin.y - textInsets.top,
            width: textRect.width + textInsets.left + textInsets.right,
            height: textRect.height + textInsets.top + textInsets.bottom
        )
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitting = super.sizeThatFits(CGSize(
            width: size.width - textInsets.left - textInsets.right,
            height: size.height - textInsets.top - textInsets.bottom
        ))
        return CGSize(
            width: fitting.width + textInsets.left + textInsets.right,
            height: fitting.height + textInsets.top + textInsets.bottom
        )
    }
}

