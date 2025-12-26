import SwiftUI
import UIKit
import OSLog

// MARK: - Logging Helper
@inline(__always)
func Log(_ message: @autoclosure () -> String,
         file: StaticString = #fileID,
         line: UInt = #line,
         function: StaticString = #function) {
    #if DEBUG
    print("[\(file):\(line)] \(function): \(message())")
    #endif
}

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
    var annotatedSpans: [AnnotatedSpan] = []
    var selectedRange: NSRange? = nil
    var customizedRanges: [NSRange] = []
    var onTokenSelection: ((SelectionPayload) -> Void)? = nil
    var onSelectionCleared: (() -> Void)? = nil

    private static let defaultInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    struct TokenOverlay: Equatable {
        let range: NSRange
        let color: UIColor

        static func == (lhs: TokenOverlay, rhs: TokenOverlay) -> Bool {
            lhs.range == rhs.range && lhs.color.isEqual(rhs.color)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> TokenOverlayTextView {
        let textView = TokenOverlayTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.textContainerInset = textInsets
        textView.clipsToBounds = false
        textView.layer.masksToBounds = false
        textView.textColor = .label
        textView.tintColor = .clear
        textView.font = UIFont.systemFont(ofSize: fontSize)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.delegate = context.coordinator
        textView.selectionDelegate = context.coordinator
        return textView
    }

    func updateUIView(_ uiView: TokenOverlayTextView, context: Context) {
        context.coordinator.parent = self
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.textColor = .label
        uiView.tintColor = .clear

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
        uiView.selectionHighlightInsets = selectionHighlightInsets(for: baseFont)
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)
        mutable.addAttribute(.font, value: baseFont, range: fullRange)

        if tokenOverlays.isEmpty == false {
            RubyText.applyTokenColors(tokenOverlays, to: mutable)
        }

        if customizedRanges.isEmpty == false {
            RubyText.applyCustomizationHighlights(customizedRanges, to: mutable)
        }

        let processed = RubyText.applyAnnotationVisibility(annotationVisibility, to: mutable)
        uiView.attributedText = processed
        uiView.annotatedSpans = annotatedSpans
        uiView.selectionHighlightRange = selectedRange
        
        // Help the view expand vertically rather than compress
        uiView.setContentCompressionResistancePriority(.required, for: .vertical)
        uiView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        uiView.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TokenOverlayTextView, context: Context) -> CGSize {
        let proposedWidth = proposal.width
        let contextScreenWidth: CGFloat? = uiView.window?.windowScene?.screen.bounds.width
        let fallbackWidth: CGFloat = (uiView.bounds.width > 0 ? uiView.bounds.width : (contextScreenWidth ?? 320))
        let baseWidth = proposedWidth ?? fallbackWidth
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

    private func selectionHighlightInsets(for font: UIFont) -> UIEdgeInsets {
        let spacing = max(0, extraGap)
        let multiplier = max(0.8, lineHeightMultiple)
        let lineHeight = font.lineHeight
        let extraFromMultiplier = max(0, lineHeight * (multiplier - 1))
        let bottom = spacing + extraFromMultiplier
        // let rubyHeadroom = max(0, font.pointSize * 0.6 + spacing)
        return UIEdgeInsets(top: -spacing, left: 0, bottom: bottom, right: 0)
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

    private static func applyCustomizationHighlights(_ ranges: [NSRange], to attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        for range in ranges {
            guard clampRange(range, length: attributedString.length) != nil else { continue }
            // attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: clamped)
            // attributedString.addAttribute(.underlineColor, value: UIColor.systemTeal, range: clamped)
        }
    }

    private static func clampRange(_ range: NSRange, length: Int) -> NSRange? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard length > 0 else { return nil }
        guard range.location < length else { return nil }
        let upperBound = min(length, NSMaxRange(range))
        let clampedLength = upperBound - range.location
        guard clampedLength > 0 else { return nil }
        return NSRange(location: range.location, length: clampedLength)
    }

    struct SelectionPayload: Equatable {
        let span: AnnotatedSpan
        let index: Int
        let range: NSRange
    }

    final class Coordinator: NSObject, UITextViewDelegate, TokenOverlaySelectionDelegate {
        var parent: RubyText

        init(parent: RubyText) {
            self.parent = parent
        }

        func tokenOverlayTextView(_ view: TokenOverlayTextView, didSelect payload: RubyText.SelectionPayload) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onTokenSelection?(payload)
            }
        }

        func tokenOverlayTextViewDidClearSelection(_ view: TokenOverlayTextView) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onSelectionCleared?()
            }
        }
    }
}

protocol TokenOverlaySelectionDelegate: AnyObject {
    func tokenOverlayTextView(_ view: TokenOverlayTextView, didSelect payload: RubyText.SelectionPayload)
    func tokenOverlayTextViewDidClearSelection(_ view: TokenOverlayTextView)
}

final class TokenOverlayTextView: UITextView {
    weak var selectionDelegate: TokenOverlaySelectionDelegate?
    var annotatedSpans: [AnnotatedSpan] = []
    var selectionHighlightRange: NSRange? {
        didSet {
            setNeedsLayout()
        }
    }
    var selectionHighlightInsets: UIEdgeInsets = .zero {
        didSet {
            if oldValue != selectionHighlightInsets {
                setNeedsLayout()
            }
        }
    }
    private static let eventLogger = DiagnosticsLogging.logger(.tokenOverlayEvents)
    private static let geometryLogger = DiagnosticsLogging.logger(.tokenOverlayGeometry)
    private static let whitespaceSet: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(CharacterSet(charactersIn: "\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{200B}"))
        return set
    }()

    private static func logEvent(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        eventLogger.debug("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }

    private static func logGeometry(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        geometryLogger.debug("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }
    private lazy var tapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTokenTap(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()
    private let selectionHighlightLayer = CAShapeLayer()

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
        isSelectable = false
        isScrollEnabled = false
        backgroundColor = .clear
        textContainer.lineFragmentPadding = 0
        textContainerInset = .zero
        clipsToBounds = false
        layer.masksToBounds = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        addGestureRecognizer(tapRecognizer)
        selectionHighlightLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.22).cgColor
        selectionHighlightLayer.zPosition = -1
        layer.insertSublayer(selectionHighlightLayer, at: 0)
    }

    override var canBecomeFirstResponder: Bool {
        false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectionHighlightLayer.frame = bounds
        updateSelectionHighlightPath()
    }

    func selectionPayload(forExactRange range: NSRange) -> RubyText.SelectionPayload? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        guard let match = spanMatching(range: range) else { return nil }
        return RubyText.SelectionPayload(span: match.span, index: match.index, range: match.span.span.range)
    }

    private func spanMatching(range: NSRange) -> (span: AnnotatedSpan, index: Int)? {
        for (index, span) in annotatedSpans.enumerated() {
            if span.span.range.location == range.location && span.span.range.length == range.length {
                return (span, index)
            }
        }
        return nil
    }

    private func spanContaining(index: Int) -> (span: AnnotatedSpan, offset: Int)? {
        annotatedSpans.enumerated().first { _, annotated in
            NSLocationInRange(index, annotated.span.range)
        }.map { (span: $0.element, offset: $0.offset) }
    }

    private func spanBefore(index: Int) -> (span: AnnotatedSpan, offset: Int)? {
        annotatedSpans.enumerated().last { _, annotated in
            NSMaxRange(annotated.span.range) <= index
        }.map { (span: $0.element, offset: $0.offset) }
    }

    private func spanAfter(index: Int) -> (span: AnnotatedSpan, offset: Int)? {
        annotatedSpans.enumerated().first { _, annotated in
            annotated.span.range.location > index
        }.map { (span: $0.element, offset: $0.offset) }
    }

    private func snapSpan(near index: Int) -> (span: AnnotatedSpan, offset: Int)? {
        guard let string = textStorage.string as NSString? else { return nil }
        var forwardCandidate: (span: AnnotatedSpan, offset: Int)?
        if let ahead = spanAfter(index: index) {
            let distance = max(0, min(ahead.span.span.range.location - index, string.length - index))
            let whitespaceRange = NSRange(location: index, length: distance)
            if whitespaceOnly(range: whitespaceRange, in: string) {
                forwardCandidate = ahead
            }
        }
        if let forwardCandidate { return forwardCandidate }
        if let behind = spanBefore(index: index) {
            let spanEnd = NSMaxRange(behind.span.span.range)
            let length = max(0, min(index - spanEnd, string.length - spanEnd))
            let whitespaceRange = NSRange(location: spanEnd, length: length)
            if whitespaceOnly(range: whitespaceRange, in: string) {
                return behind
            }
        }
        return nil
    }

    private func whitespaceOnly(range: NSRange, in string: NSString) -> Bool {
        guard range.length > 0 else { return true }
        guard range.location >= 0, NSMaxRange(range) <= string.length else { return false }
        for idx in range.location..<NSMaxRange(range) {
            let scalar = UnicodeScalar(string.character(at: idx))
            if scalar == nil || TokenOverlayTextView.whitespaceSet.contains(scalar!) == false {
                return false
            }
        }
        return true
    }

    @objc private func handleTokenTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let tapPoint = gesture.location(in: self)
        Self.logEvent("Tap at x=\(tapPoint.x) y=\(tapPoint.y)")
        guard let index = characterIndex(at: tapPoint) else {
            Self.logEvent("Tap ignored: no glyph resolved; clearing selection")
            selectionHighlightRange = nil
            selectionDelegate?.tokenOverlayTextViewDidClearSelection(self)
            return
        }
        Self.logEvent("index=\(index)") // annotatedSpans=\(annotatedSpans.enumerated())
        if let match = spanContaining(index: index) {
            deliverSelection(match.span, offset: match.offset)
            return
        }

        if let snapped = snapSpan(near: index) {
            Self.logEvent("Snapped selection to span index=\(snapped.offset)")
            deliverSelection(snapped.span, offset: snapped.offset)
            return
        }

        selectedRange = NSRange(location: index, length: 0)
        Self.logEvent("Cleared selection at index=\(index)")
        selectionDelegate?.tokenOverlayTextViewDidClearSelection(self)
    }

    private func deliverSelection(_ span: AnnotatedSpan, offset: Int) {
        let spanRange = span.span.range
        let payload = RubyText.SelectionPayload(span: span, index: offset, range: spanRange)
        Self.logEvent("Selected span index=\(offset) range=\(spanRange.location)-\(NSMaxRange(spanRange))")
        selectionDelegate?.tokenOverlayTextView(self, didSelect: payload)
    }

    private func characterIndex(at point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)

        var location = point
        location.x -= textContainerInset.left
        location.y -= textContainerInset.top
        location.x += contentOffset.x
        location.y += contentOffset.y

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: location, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        var lineRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange, withoutAdditionalLayout: true)
        let paddedRect = lineRect.insetBy(dx: -4, dy: -4)
        guard paddedRect.contains(location) else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex < textStorage.length else { return nil }
        return characterIndex
    }

    private func updateSelectionHighlightPath() {
        guard let range = selectionHighlightRange,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else {
            selectionHighlightLayer.path = nil
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            selectionHighlightLayer.path = nil
            return
        }

        let path = UIBezierPath()
        var loggedRectCount = 0
        Self.logEvent("Highlight range location=\(range.location) length=\(range.length) glyphLength=\(glyphRange.length)")

        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: glyphRange,
            in: textContainer
        ) { rect, _ in
            guard rect.isNull == false, rect.isEmpty == false else { return }
            let textRect = rect
            var highlightRect = rect
            let insets = self.selectionHighlightInsets
            if insets != .zero {
                highlightRect.origin.x += insets.left
                highlightRect.origin.y += insets.top
                highlightRect.size.width -= (insets.left + insets.right)
                highlightRect.size.height -= (insets.top + insets.bottom)
            }
            guard highlightRect.width > 0, highlightRect.height > 0 else { return }

            let offsetX = self.textContainerInset.left - self.contentOffset.x
            let offsetY = self.textContainerInset.top - self.contentOffset.y
            highlightRect = highlightRect.offsetBy(dx: offsetX, dy: offsetY)
            path.append(UIBezierPath(roundedRect: highlightRect, cornerRadius: 4))

            if loggedRectCount < 3 {
                var textRectInLayer = textRect
                if insets != .zero {
                    textRectInLayer.origin.x += insets.left
                    textRectInLayer.origin.y += insets.top
                    textRectInLayer.size.width -= (insets.left + insets.right)
                    textRectInLayer.size.height -= (insets.top + insets.bottom)
                }
                textRectInLayer = textRectInLayer.offsetBy(dx: offsetX, dy: offsetY)
                Self.logGeometry("Selection #\(loggedRectCount) textOrigin=(\(textRectInLayer.origin.x), \(textRectInLayer.origin.y)) textSize=(\(textRectInLayer.width), \(textRectInLayer.height)) highlightOrigin=(\(highlightRect.origin.x), \(highlightRect.origin.y)) highlightSize=(\(highlightRect.width), \(highlightRect.height))")
                loggedRectCount += 1
            }
        }

        selectionHighlightLayer.path = path.isEmpty ? nil : path.cgPath
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

