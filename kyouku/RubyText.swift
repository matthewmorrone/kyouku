import SwiftUI
import UIKit

extension NSAttributedString.Key {
    static let rubyAnnotation = NSAttributedString.Key("RubyAnnotation")
}

enum RubyAnnotationVisibility {
    case visible
    case hiddenKeepMetrics
    case removed
}

struct RubyText: UIViewRepresentable {
    var attributed: NSAttributedString
    var fontSize: CGFloat
    var lineHeightMultiple: CGFloat
    var extraGap: CGFloat
    var textInsets: UIEdgeInsets = RubyText.defaultInsets
    var annotationVisibility: RubyAnnotationVisibility = .visible
    var tokenOverlays: [TokenOverlay] = []

    private static let defaultInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    struct TokenOverlay: Equatable {
        let range: NSRange
        let color: UIColor

        static func == (lhs: TokenOverlay, rhs: TokenOverlay) -> Bool {
            lhs.range == rhs.range && lhs.color.isEqual(rhs.color)
        }
    }

    func makeUIView(context: Context) -> TokenOverlayTextView {
        let textView = TokenOverlayTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainerInset = textInsets
        textView.clipsToBounds = false
        textView.layer.masksToBounds = false
        textView.textColor = .label
        textView.font = UIFont.systemFont(ofSize: fontSize)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: TokenOverlayTextView, context: Context) {
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.textColor = .label

        // Compute extra headroom for ruby above the baseline.
        // Tune the multiplier as needed; 0.6 is a reasonable starting point.
        let rubyHeadroom = max(0, fontSize * 0.6 + extraGap)

        var insets = textInsets
        insets.top = max(insets.top, rubyHeadroom)
        uiView.textContainerInset = insets

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = max(0.8, lineHeightMultiple)
        paragraph.lineSpacing = max(0, extraGap)
        let baseFont = UIFont.systemFont(ofSize: fontSize)
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)
        mutable.addAttribute(.font, value: baseFont, range: fullRange)

        if tokenOverlays.isEmpty == false {
            RubyText.applyTokenColors(tokenOverlays, to: mutable)
        }

        let processed = RubyText.applyAnnotationVisibility(annotationVisibility, to: mutable)
        uiView.attributedText = processed
        
        // Help the view expand vertically rather than compress
        uiView.setContentCompressionResistancePriority(.required, for: .vertical)
        uiView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        uiView.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TokenOverlayTextView, context: Context) -> CGSize {
        let proposedWidth = proposal.width
        let baseWidth = (proposedWidth ?? (uiView.bounds.width > 0 ? uiView.bounds.width : UIScreen.main.bounds.width))
        let insets = uiView.textContainerInset
        let availableWidth = max(0, baseWidth - insets.left - insets.right)

        // Drive the text container for measurement
        uiView.textContainer.size = CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        uiView.textContainer.widthTracksTextView = false
        uiView.layoutManager.ensureLayout(for: uiView.textContainer)
        let used = uiView.layoutManager.usedRect(for: uiView.textContainer)
        var measuredHeight = ceil(used.height) + insets.top + insets.bottom

        // Fallback if TextKit reports 0 height but we have text
        if measuredHeight <= 0, (uiView.attributedText?.length ?? 0) > 0 {
            let fitting = uiView.sizeThatFits(CGSize(width: baseWidth, height: .greatestFiniteMagnitude))
            measuredHeight = max(measuredHeight, fitting.height)
        }

        // Restore normal behavior
        uiView.textContainer.widthTracksTextView = true
        return CGSize(width: baseWidth, height: measuredHeight)
    }

    private static let coreTextRubyAttribute = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

    private static func applyAnnotationVisibility(
        _ visibility: RubyAnnotationVisibility,
        to attributedString: NSMutableAttributedString
    ) -> NSAttributedString {
        guard attributedString.length > 0 else { return attributedString }
        switch visibility {
        case .visible:
            return attributedString
        case .hiddenKeepMetrics:
            hideAnnotationRuns(in: attributedString)
            return attributedString
        case .removed:
            return removeAnnotationRuns(from: attributedString)
        }
    }

    private static func annotationRanges(in attributedString: NSAttributedString) -> [NSRange] {
        guard attributedString.length > 0 else { return [] }
        var ranges: [NSRange] = []
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttribute(.rubyAnnotation, in: fullRange, options: []) { value, range, _ in
            guard let isAnnotation = value as? Bool, isAnnotation == true else { return }
            guard range.location != NSNotFound, range.length > 0 else { return }
            guard NSMaxRange(range) <= attributedString.length else { return }
            ranges.append(range)
        }
        return ranges
    }

    private static func hideAnnotationRuns(in attributedString: NSMutableAttributedString) {
        for range in annotationRanges(in: attributedString) {
            attributedString.removeAttribute(coreTextRubyAttribute, range: range)
        }
    }

    private static func removeAnnotationRuns(from attributedString: NSMutableAttributedString) -> NSAttributedString {
        let ranges = annotationRanges(in: attributedString)
        guard ranges.isEmpty == false else { return attributedString }
        for range in ranges {
            attributedString.removeAttribute(coreTextRubyAttribute, range: range)
            attributedString.removeAttribute(.rubyAnnotation, range: range)
        }
        return attributedString
    }

    private static func applyTokenColors(
        _ overlays: [TokenOverlay],
        to attributedString: NSMutableAttributedString
    ) {
        guard attributedString.length > 0 else { return }
        let length = attributedString.length
        for overlay in overlays {
            guard overlay.range.location != NSNotFound, overlay.range.length > 0 else { continue }
            guard NSMaxRange(overlay.range) <= length else { continue }
            attributedString.addAttribute(.foregroundColor, value: overlay.color, range: overlay.range)
        }
    }
}

final class TokenOverlayTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        sharedInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        sharedInit()
    }

    private func sharedInit() {
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainer.lineFragmentPadding = 0
        textContainerInset = .zero
        clipsToBounds = false
        layer.masksToBounds = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
    }
}

enum RubyAnnotationHelper {
    /// Marks the specified range as a ruby annotation run.
    static func markAnnotation(in attributedString: NSMutableAttributedString, range: NSRange) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        guard NSMaxRange(range) <= attributedString.length else { return }
        attributedString.addAttribute(.rubyAnnotation, value: true, range: range)
    }

    /// Creates a standalone ruby annotation attributed string segment.
    static func annotationSegment(
        _ text: String,
        attributes: [NSAttributedString.Key: Any]? = nil
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(string: text, attributes: attributes)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.rubyAnnotation, value: true, range: fullRange)
        return mutable
    }
}

