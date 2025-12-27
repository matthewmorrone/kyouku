import SwiftUI
import UIKit
import OSLog
#if DEBUG
import ObjectiveC
#endif

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
        uiView.applyAttributedText(processed)
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
        let targetSize = CGSize(width: baseWidth, height: .greatestFiniteMagnitude)
        let measured = uiView.sizeThatFits(targetSize)
        let measuredHeight = measured.height > 0 ? measured.height : targetSize.height
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
            guard oldValue != selectionHighlightRange else { return }
            updateSelectionHighlightPath()
        }
    }
    var selectionHighlightInsets: UIEdgeInsets = .zero {
        didSet {
            guard oldValue != selectionHighlightInsets else { return }
            updateSelectionHighlightPath()
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

    private var selectionHighlightPath: UIBezierPath? = nil

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        sharedInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        sharedInit()
    }

    private func sharedInit() {
#if DEBUG
        Self.installTextKit1AccessGuardsIfNeeded()
#endif
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
        updateInspectionGestureState()
    }

    override var canBecomeFirstResponder: Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSelectionHighlightPath()
    }

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

    func applyAttributedText(_ text: NSAttributedString) {
        attributedText = text
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func updateSelectionHighlightPath() {
        guard let range = selectionHighlightRange,
              range.location != NSNotFound,
              range.length > 0,
              let attributedLength = attributedText?.length,
              NSMaxRange(range) <= attributedLength,
              let uiRange = textRange(for: range) else {
            selectionHighlightPath = nil
            setNeedsDisplay()
            return
        }

        let rects = selectionRects(for: uiRange)
            .map { $0.rect }
            .filter { $0.isNull == false && $0.isEmpty == false }

        guard rects.isEmpty == false else {
            selectionHighlightPath = nil
            setNeedsDisplay()
            return
        }

        let path = UIBezierPath()
        let insets = selectionHighlightInsets
        for rect in rects {
            var highlightRect = rect
            if insets != .zero {
                highlightRect.origin.x += insets.left
                highlightRect.origin.y += insets.top
                highlightRect.size.width -= (insets.left + insets.right)
                highlightRect.size.height -= (insets.top + insets.bottom)
            }
            guard highlightRect.width > 0, highlightRect.height > 0 else { continue }

            if let baseFont = font {
                let desiredHeight = min(baseFont.lineHeight, highlightRect.height)
                highlightRect.origin.y = highlightRect.maxY - desiredHeight
                highlightRect.size.height = desiredHeight
            }

            path.append(UIBezierPath(roundedRect: highlightRect, cornerRadius: 4))
        }

        selectionHighlightPath = path.isEmpty ? nil : path
        setNeedsDisplay()
    }

    private func textRange(for nsRange: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: nsRange.location),
              let end = position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textRange(from: start, to: end)
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
    }

    private func utf16IndexForTap(at point: CGPoint) -> Int? {
        guard let attributedLength = attributedText?.length, attributedLength > 0 else { return nil }
        guard let textRange = characterRange(at: point) ?? textRangeNearPoint(point) else { return nil }
        let offset = offset(from: beginningOfDocument, to: textRange.start)
        guard offset >= 0, offset < attributedLength else { return nil }

        let rect = firstRect(for: textRange)
        if rect.isNull == false {
            let toleranceRect = rect.insetBy(dx: -8, dy: -8)
            guard toleranceRect.contains(point) else {
                Self.logEvent("Hit-test rejected: point outside tolerance rect")
                return nil
            }
        }

        return offset
    }

    private func textRangeNearPoint(_ point: CGPoint) -> UITextRange? {
        guard let closestPosition = closestPosition(to: point) else { return nil }
        if let next = position(from: closestPosition, offset: 1) {
            return textRange(from: closestPosition, to: next)
        }
        if let previous = position(from: closestPosition, offset: -1) {
            return textRange(from: previous, to: closestPosition)
        }
        return nil
    }

    private func resolvedTextIndex(from candidate: Int) -> Int? {
        guard let length = attributedText?.length, length > 0 else { return nil }
        guard candidate >= 0, candidate < length else { return nil }
        return candidate
    }

    private func inspectionDetails(forUTF16Index index: Int) -> (character: Character, utf16Range: NSRange, scalars: [String])? {
        guard let backingString = attributedText?.string else { return nil }
        let utf16View = backingString.utf16
        guard index >= 0, index < utf16View.count else { return nil }

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

#if DEBUG
    private static var textKit1GuardsInstalled = false

    private static func installTextKit1AccessGuardsIfNeeded() {
        guard textKit1GuardsInstalled == false else { return }
        textKit1GuardsInstalled = true
        installTextViewGuard(
            original: #selector(getter: UITextView.layoutManager),
            swizzled: #selector(TokenOverlayTextView.tk1_guarded_layoutManager),
            name: "layoutManager"
        )
        installTextViewGuard(
            original: #selector(getter: UITextView.textStorage),
            swizzled: #selector(TokenOverlayTextView.tk1_guarded_textStorage),
            name: "textStorage"
        )
        installGlyphRangeGuard()
    }

    private static func installTextViewGuard(original: Selector, swizzled: Selector, name: String) {
        guard let method = class_getInstanceMethod(TokenOverlayTextView.self, original),
              let swizzledMethod = class_getInstanceMethod(TokenOverlayTextView.self, swizzled) else {
            logEvent("Unable to install TextKit 1 guard for \(name)")
            return
        }
        method_exchangeImplementations(method, swizzledMethod)
    }

    private static func installGlyphRangeGuard() {
        guard let original = class_getInstanceMethod(NSLayoutManager.self, #selector(NSLayoutManager.glyphRange(for:))),
              let swizzled = class_getInstanceMethod(NSLayoutManager.self, #selector(NSLayoutManager.tk1_guardedGlyphRange(for:))) else {
            logEvent("Unable to install TextKit 1 guard for glyphRange(for:)")
            return
        }
        method_exchangeImplementations(original, swizzled)
    }

    static func debugReportTextKit1Access(_ symbol: String) {
        let message = "⚠️ TextKit 1 API accessed: \(symbol). Use TextKit 2 layout primitives instead."
        logEvent(message)
        assertionFailure(message)
    }

    @objc private func tk1_guarded_layoutManager() -> NSLayoutManager {
        Self.debugReportTextKit1Access("layoutManager")
        return tk1_guarded_layoutManager()
    }

    @objc private func tk1_guarded_textStorage() -> NSTextStorage {
        Self.debugReportTextKit1Access("textStorage")
        return tk1_guarded_textStorage()
    }
#endif
}

#if DEBUG
extension NSLayoutManager {
    @objc fileprivate func tk1_guardedGlyphRange(for textContainer: NSTextContainer) -> NSRange {
        TokenOverlayTextView.debugReportTextKit1Access("glyphRange(for:)")
        return tk1_guardedGlyphRange(for: textContainer)
    }
}
#endif

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

