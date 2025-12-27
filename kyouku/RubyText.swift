import SwiftUI
import UIKit
import OSLog

    // MARK: - Logging Helper
@inline(__always)
func Log(_ message: @autoclosure () -> String,
         file: StaticString = #fileID,
         line: UInt = #line,
         function: StaticString = #function) {
    print("[\(file):\(line)] \(function): \(message())")
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
    var enableTapInspection: Bool = true
    
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
        textView.isTapInspectionEnabled = enableTapInspection
        return textView
    }
    
    func updateUIView(_ uiView: TokenOverlayTextView, context: Context) {
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
        uiView.applyCanonicalAttributedText(processed)
        uiView.annotatedSpans = annotatedSpans
        uiView.selectionHighlightRange = selectedRange
        uiView.isTapInspectionEnabled = enableTapInspection
        
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
        return UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
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
    
}

final class TokenOverlayTextView: UITextView {
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
    var isTapInspectionEnabled: Bool = true {
        didSet {
            guard oldValue != isTapInspectionEnabled else { return }
            updateInspectionGestureState()
        }
    }
    
    private static let eventLogger = DiagnosticsLogging.logger(.tokenOverlayEvents)
    private static let geometryLogger = DiagnosticsLogging.logger(.tokenOverlayGeometry)
    
    private static func logEvent(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        eventLogger.debug("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }
    
    private static func logGeometry(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        geometryLogger.debug("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }
    private lazy var inspectionTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInspectionTap(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()
        // 1) Replace CAShapeLayer with bezier path storage
    private var selectionHighlightPath: UIBezierPath? = nil
    private var canonicalAttributedText: NSAttributedString?
    
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
            // 2) Remove layer setup for selectionHighlightLayer
            // Removed these lines:
            // selectionHighlightLayer.fillColor = UIColor.systemYellow.withAlphaComponent(0.22).cgColor
            // selectionHighlightLayer.zPosition = -1
            // layer.insertSublayer(selectionHighlightLayer, at: 0)
        updateInspectionGestureState()
    }
    
    override var canBecomeFirstResponder: Bool {
        false
    }
    
        // 3) Replace layoutSubviews body
    override func layoutSubviews() {
        super.layoutSubviews()
        updateSelectionHighlightPath()
        setNeedsDisplay()
    }
    
        // 5) Add draw override to paint highlight beneath text
    override func draw(_ rect: CGRect) {
        if let path = selectionHighlightPath {
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.saveGState()
            UIColor.systemYellow.withAlphaComponent(0.22).setFill()
            path.fill()
            ctx?.restoreGState()
        }
        super.draw(rect)
    }
    
    func applyCanonicalAttributedText(_ text: NSAttributedString) {
        let snapshot = NSAttributedString(attributedString: text)
        canonicalAttributedText = snapshot
        replaceDisplayedText(with: snapshot)
    }
    
    private func restoreCanonicalAttributedTextIfNeeded() {
        guard let canonical = canonicalAttributedText else { return }
        replaceDisplayedText(with: canonical)
    }
    
    private func replaceDisplayedText(with text: NSAttributedString) {
        if textStorage.length > 0 {
            textStorage.beginEditing()
            textStorage.setAttributedString(text)
            textStorage.endEditing()
        } else {
            textStorage.setAttributedString(text)
        }
        attributedText = text
        setNeedsDisplay()
    }
    
        // 4) Modify updateSelectionHighlightPath to store path instead of assigning to layer
    private func updateSelectionHighlightPath() {
        selectionHighlightPath = nil
        
        guard let range = selectionHighlightRange,
              range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else {
            selectionHighlightPath = nil
            return
        }
        
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else {
            selectionHighlightPath = nil
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
            
                // Constrain highlight to base text line height to avoid overlapping ruby
            if let baseFont = self.font {
                let baseHeight = baseFont.lineHeight
                if baseHeight > 0 {
                    let desiredHeight = min(highlightRect.height, baseHeight)
                        // Anchor to the baseline area: keep the bottom of the rect and reduce height from the top
                    highlightRect.origin.y = highlightRect.maxY - desiredHeight
                    highlightRect.size.height = desiredHeight
                }
            }
            
            path.append(UIBezierPath(roundedRect: highlightRect, cornerRadius: 4))
            
            if loggedRectCount < 3 {
                var textRectInLayer = textRect
                if insets != .zero {
                    textRectInLayer.origin.x += insets.left
                    textRectInLayer.origin.y += insets.top
                    textRectInLayer.size.width -= (insets.left + insets.right)
                    textRectInLayer.size.height -= (insets.top + insets.bottom)
                }
                Self.logGeometry("Selection #\(loggedRectCount) textOrigin=(\(textRectInLayer.origin.x), \(textRectInLayer.origin.y)) textSize=(\(textRectInLayer.width), \(textRectInLayer.height)) highlightOrigin=(\(highlightRect.origin.x), \(highlightRect.origin.y)) highlightSize=(\(highlightRect.width), \(highlightRect.height))")
                loggedRectCount += 1
            }
        }
        
        selectionHighlightPath = path.isEmpty ? nil : path
    }
    
    private func updateInspectionGestureState() {
        if isTapInspectionEnabled {
            let alreadyAdded = gestureRecognizers?.contains(where: { $0 === inspectionTapRecognizer }) ?? false
            if alreadyAdded == false {
                addGestureRecognizer(inspectionTapRecognizer)
            }
        } else {
            let alreadyAdded = gestureRecognizers?.contains(where: { $0 === inspectionTapRecognizer }) ?? false
            if alreadyAdded {
                removeGestureRecognizer(inspectionTapRecognizer)
            }
        }
    }
    
    @objc
    private func handleInspectionTap(_ recognizer: UITapGestureRecognizer) {
        guard isTapInspectionEnabled, recognizer.state == .ended else { return }
        restoreCanonicalAttributedTextIfNeeded()
        let tapPoint = recognizer.location(in: self)
        Self.logEvent("Inspect tap at x=\(tapPoint.x) y=\(tapPoint.y)")
        
        guard let rawIndex = utf16IndexForTap(at: tapPoint) else {
            Self.logEvent("Inspect tap ignored: no glyph resolved")
            return
        }
        
        guard let resolvedIndex = resolvedTextIndex(from: rawIndex) else {
            Self.logEvent("Inspect tap unresolved: no base character near index=\(rawIndex)")
            return
        }
        
        guard let details = inspectionDetails(forUTF16Index: resolvedIndex) else {
            Self.logEvent("Inspect tap unresolved: failed to extract character at index=\(resolvedIndex)")
            return
        }
        
        let charDescription = formattedCharacterDescription(details.character)
        let rangeDescription = "[\(details.utf16Range.location)..<\(NSMaxRange(details.utf16Range))]"
        let scalarsDescription = details.scalars.joined(separator: ", ")
        let indexSummary = rawIndex == resolvedIndex ? "\(resolvedIndex)" : "\(resolvedIndex) (resolved from \(rawIndex))"
        
        Self.logEvent(
            "Inspect tap char=\(charDescription) utf16Index=\(indexSummary) utf16Range=\(rangeDescription) scalars=[\(scalarsDescription)]"
        )
        restoreCanonicalAttributedTextIfNeeded()
    }
    
    private func utf16IndexForTap(at point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return nil }

        layoutManager.ensureLayout(for: textContainer)

        var location = point
        location.x -= textContainerInset.left
        location.y -= textContainerInset.top
        location.x += contentOffset.x
        location.y += contentOffset.y

        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(
            for: location,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )

        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }

        var lineRange = NSRange(location: 0, length: 0)
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &lineRange,
            withoutAdditionalLayout: true
        )
        let toleranceRect = lineRect.insetBy(dx: -6, dy: -6)
        guard toleranceRect.contains(location) else {
            Self.logEvent("Hit-test rejected: tap outside line rect for glyph=\(glyphIndex)")
            return nil
        }

        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard characterIndex >= 0, characterIndex < textStorage.length else { return nil }

        Self.logEvent("Hit-test success glyphIndex=\(glyphIndex) utf16Index=\(characterIndex)")
        return characterIndex
    }
    
    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        if rect.contains(point) { return 0 }
        let dx: CGFloat
        if point.x < rect.minX { dx = rect.minX - point.x }
        else if point.x > rect.maxX { dx = point.x - rect.maxX }
        else { dx = 0 }
        
        let dy: CGFloat
        if point.y < rect.minY { dy = rect.minY - point.y }
        else if point.y > rect.maxY { dy = point.y - rect.maxY }
        else { dy = 0 }
        
        return hypot(dx, dy)
    }
    
    private func resolvedTextIndex(from candidate: Int) -> Int? {
        guard textStorage.length > 0 else { return nil }
        guard candidate >= 0, candidate < textStorage.length else { return nil }
        return candidate
    }
    
    private func inspectionDetails(forUTF16Index index: Int) -> (character: Character, utf16Range: NSRange, scalars: [String])? {
        guard index >= 0, index < textStorage.length else { return nil }
        let backingString = textStorage.string
        guard backingString.isEmpty == false else { return nil }
        
        let utf16View = backingString.utf16
        guard let startUTF16 = utf16View.index(utf16View.startIndex, offsetBy: index, limitedBy: utf16View.endIndex) else {
            return nil
        }
        guard let startIndex = String.Index(startUTF16, within: backingString) else { return nil }
        let character = backingString[startIndex]
        let nextIndex = backingString.index(after: startIndex)
        guard let endUTF16 = nextIndex.samePosition(in: utf16View) else { return nil }
        let length = utf16View.distance(from: startUTF16, to: endUTF16)
        let nsRange = NSRange(location: index, length: length)
        let scalars = character.unicodeScalars.map { scalar in
            String(format: "U+%04X", scalar.value)
        }
        return (character, nsRange, scalars)
    }
    
    private func formattedCharacterDescription(_ character: Character) -> String {
        character.debugDescription
    }
    
}

extension AnnotatedSpan {
    var range: NSRange { span.range }
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

