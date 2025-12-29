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

struct RubySpanSelection {
    let spanIndex: Int
    let annotatedSpan: AnnotatedSpan
    let highlightRange: NSRange
}

struct RubyContextMenuState {
    let canMergeLeft: Bool
    let canMergeRight: Bool
    let canSplit: Bool
}

enum RubyContextMenuAction {
    case mergeLeft
    case mergeRight
    case split
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
    var onSpanSelection: ((RubySpanSelection?) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var onContextMenuAction: ((RubyContextMenuAction) -> Void)? = nil

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
        textView.spanSelectionHandler = onSpanSelection
        textView.contextMenuStateProvider = contextMenuStateProvider
        textView.contextMenuActionHandler = onContextMenuAction
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
        uiView.rubyHighlightHeadroom = rubyHeadroom

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
        uiView.spanSelectionHandler = onSpanSelection
        uiView.contextMenuStateProvider = contextMenuStateProvider
        uiView.contextMenuActionHandler = onContextMenuAction

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
        _ = uiView.textContainerInset
        let targetSize = CGSize(width: baseWidth, height: .greatestFiniteMagnitude)
        let measured = uiView.sizeThatFits(targetSize)
        let measuredHeight = measured.height > 0 ? measured.height : targetSize.height
        return CGSize(width: baseWidth, height: measuredHeight)
    }

    private func selectionHighlightInsets(for font: UIFont) -> UIEdgeInsets {
        // let rubyAllowance = -max(0, font.pointSize * 0.9)
        let spacing = max(0, extraGap)
        let bottomInset = max(0, spacing * 0.15)
        return UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
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

final class TokenOverlayTextView: UITextView, UIContextMenuInteractionDelegate {
    var annotatedSpans: [AnnotatedSpan] = []

    var selectionHighlightRange: NSRange? {
        didSet {
            guard oldValue != selectionHighlightRange else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            Self.logGeometry("selectionHighlightRange didSet -> setNeedsLayout (range=\(String(describing: selectionHighlightRange)))")
        }
    }

    var selectionHighlightInsets: UIEdgeInsets = .zero {
        didSet {
            guard oldValue != selectionHighlightInsets else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            Self.logGeometry(String(format: "selectionHighlightInsets didSet -> setNeedsLayout (top=%.2f left=%.2f bottom=%.2f right=%.2f)", selectionHighlightInsets.top, selectionHighlightInsets.left, selectionHighlightInsets.bottom, selectionHighlightInsets.right))
        }
    }

    var isTapInspectionEnabled: Bool = true {
        didSet {
            guard oldValue != isTapInspectionEnabled else { return }
            updateInspectionGestureState()
        }
    }

    var spanSelectionHandler: ((RubySpanSelection?) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var contextMenuActionHandler: ((RubyContextMenuAction) -> Void)? = nil

    private static let eventLogger = DiagnosticsLogging.logger(.tokenOverlayEvents)
    private static let geometryLogger = DiagnosticsLogging.logger(.tokenOverlayGeometry)

    private static func logEvent(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        eventLogger.debug("[\(file):\(line)] \(function): \(message, privacy: .public)")
    }

    private static func logGeometry(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        geometryLogger.debug("[\(file):\(line)]: \(message, privacy: .public)")
    }

    private lazy var inspectionTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInspectionTap(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    private lazy var spanContextMenuInteraction = UIContextMenuInteraction(delegate: self)

    // Base and ruby highlights are separate paths so the base highlight can remain
    // tightly clamped to the glyph line-height while the ruby highlight occupies only
    // the reserved ruby headroom above it.
    private var textSelectionHighlightPath: UIBezierPath? = nil
    private var rubySelectionHighlightPath: UIBezierPath? = nil
    var rubyHighlightHeadroom: CGFloat = 0 {
        didSet {
            guard oldValue != rubyHighlightHeadroom else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            Self.logGeometry(String(format: "rubyHighlightHeadroom didSet -> setNeedsLayout (headroom=%.2f)", rubyHighlightHeadroom))
        }
    }

    private var needsHighlightUpdate: Bool = false

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
        addInteraction(spanContextMenuInteraction)
        needsHighlightUpdate = true
    }

    override var canBecomeFirstResponder: Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
//        Self.logGeometry("layoutSubviews: needsHighlightUpdate=\(needsHighlightUpdate)")
        if needsHighlightUpdate {
            updateSelectionHighlightPath()
            needsHighlightUpdate = false
//            Self.logGeometry("layoutSubviews: performed highlight update")
        }
    }

    override func draw(_ rect: CGRect) {
        if let rubyPath = rubySelectionHighlightPath {
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.saveGState()
            UIColor.systemYellow.withAlphaComponent(0.25).setFill()
            rubyPath.fill()
            UIColor.systemYellow.withAlphaComponent(0.55).setStroke()
            rubyPath.lineWidth = 1.0
            rubyPath.stroke()
            ctx?.restoreGState()
        }
        if let path = textSelectionHighlightPath {
            let ctx = UIGraphicsGetCurrentContext()
            ctx?.saveGState()
            UIColor.systemYellow.withAlphaComponent(0.38).setFill()
            path.fill()
            UIColor.systemYellow.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1.0
            path.stroke()
            ctx?.restoreGState()
        }
        super.draw(rect)
    }

    func applyAttributedText(_ text: NSAttributedString) {
        attributedText = text
        needsHighlightUpdate = true
        setNeedsLayout()
        Self.logGeometry("applyAttributedText -> setNeedsLayout")
    }

    private func updateSelectionHighlightPath() {
        guard let range = selectionHighlightRange,
              range.location != NSNotFound,
              range.length > 0,
              let attributedLength = attributedText?.length,
              NSMaxRange(range) <= attributedLength,
              let uiRange = textRange(for: range) else {
            textSelectionHighlightPath = nil
            rubySelectionHighlightPath = nil
            setNeedsDisplay()
            return
        }

        // Base (headword) highlight uses the FULL selected span range (including okurigana).
        // We clamp vertically to the base glyph line-height so it never covers ruby space.
        let rects = selectionRects(for: uiRange)
            .map { $0.rect }
            .filter { $0.isNull == false && $0.isEmpty == false }

        guard rects.isEmpty == false else {
            textSelectionHighlightPath = nil
            rubySelectionHighlightPath = nil
            setNeedsDisplay()
            return
        }

        // Furigana highlight prefers measured geometry via TextKit 2 line fragments when available
        // (using `textLayoutManager` + layout fragments). On older OS versions or when unavailable,
        // we fall back to synthesizing ruby rectangles from base glyph rectangles plus configured headroom.
        let shouldDrawRuby = selectionHasRuby(for: range)

        let basePath = UIBezierPath()
        let rubyPath = shouldDrawRuby ? UIBezierPath() : nil
        let insets = selectionHighlightInsets

        for rect in rects {
            var highlightRect = rect

            // Clamp to base glyph area only (ignore ruby headroom)
            let lineHeight = font?.lineHeight ?? rect.height
            highlightRect.origin.y = rect.maxY - lineHeight
            highlightRect.size.height = lineHeight

            if insets != .zero {
                highlightRect.origin.x += insets.left
                highlightRect.origin.y += insets.top
                highlightRect.size.width -= (insets.left + insets.right)
                highlightRect.size.height -= (insets.top + insets.bottom)
            }
            guard highlightRect.width > 0, highlightRect.height > 0 else { continue }

            Self.logGeometry(String(format: "BASE highlight rect x=%.2f y=%.2f w=%.2f h=%.2f", highlightRect.origin.x, highlightRect.origin.y, highlightRect.size.width, highlightRect.size.height))
            basePath.append(UIBezierPath(roundedRect: highlightRect, cornerRadius: 4))
        }

        if let rubyPath, shouldDrawRuby {
            // Furigana highlight prefers measured geometry via TextKit 2 line fragments when available
            // (using `textLayoutManager` + layout fragments). On older OS versions or when unavailable,
            // we fall back to synthesizing ruby rectangles from base glyph rectangles plus configured headroom.
            for rubyRect in rubyHighlightRects(in: range) {
                Self.logGeometry(String(format: "RUBY highlight rect x=%.2f y=%.2f w=%.2f h=%.2f", rubyRect.origin.x, rubyRect.origin.y, rubyRect.size.width, rubyRect.size.height))

                let clamped = rubyRect.intersection(bounds)
                if clamped.isNull == false, clamped.isEmpty == false {
//                    Self.logGeometry(String(format: "RUBY highlight rect x=%.2f y=%.2f w=%.2f h=%.2f", clamped.origin.x, clamped.origin.y, clamped.size.width, clamped.size.height))
                    rubyPath.append(UIBezierPath(roundedRect: clamped, cornerRadius: 4))
                }
            }
        }

        textSelectionHighlightPath = basePath.isEmpty ? nil : basePath
        if let rubyPath, rubyPath.isEmpty == false {
            rubySelectionHighlightPath = rubyPath
        } else {
            rubySelectionHighlightPath = nil
        }
        setNeedsDisplay()
    }

    private func rubyHighlightRects(in selectionRange: NSRange) -> [CGRect] {
        guard let attributedText else { return [] }
        guard selectionRange.location != NSNotFound, selectionRange.length > 0 else { return [] }
        guard NSMaxRange(selectionRange) <= attributedText.length else { return [] }

        // Gather ruby-bearing subranges inside the selected span.
        let coreRubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        var rubyRanges: [NSRange] = []
        attributedText.enumerateAttribute(coreRubyKey, in: selectionRange, options: []) { value, range, _ in
            guard value != nil else { return }
            guard range.location != NSNotFound, range.length > 0 else { return }
            rubyRanges.append(range)
        }
        guard rubyRanges.isEmpty == false else { return [] }

        var results: [CGRect] = []

        for rubyRange in rubyRanges {
            // Collect base rects for this ruby-bearing subrange (used for horizontal extents)
            var baseRects: [CGRect] = []
            if let uiRubyRange = textRange(for: rubyRange) {
                baseRects = selectionRects(for: uiRubyRange)
                    .map { $0.rect }
                    .filter { $0.isNull == false && $0.isEmpty == false }
            }
            guard baseRects.isEmpty == false else { continue }

            // iOS 16+: Prefer measured line fragment geometry for vertical bounds
            if #available(iOS 16.0, *), let tlm = textLayoutManager {
                let inset = textContainerInset
                // Build an array of line rects in view coordinates
                var lineRects: [CGRect] = []

                // Ensure layout so fragments are available
                tlm.ensureLayout(for: tlm.documentRange)

                // Enumerate TextKit 2 layout fragments
                tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
                    for line in fragment.textLineFragments {
                        let r = line.typographicBounds
                        let viewRect = CGRect(
                            x: r.origin.x + inset.left,
                            y: r.origin.y + inset.top,
                            width: r.size.width,
                            height: r.size.height
                        )
                        lineRects.append(viewRect)
                    }
                    return false // continue enumeration
                }

                if lineRects.isEmpty == false {
                    // For each base segment, derive a ruby band from the line's measured top to the base segment's top
                    for rect in baseRects {
                        var baseRect = rect
                        let lineHeight = font?.lineHeight ?? rect.height
                        baseRect.origin.y = rect.maxY - lineHeight
                        baseRect.size.height = lineHeight

                        // Choose the line rect with the greatest vertical intersection with this base segment
                        if let lineRect = lineRects.max(by: { $0.intersection(baseRect).height < $1.intersection(baseRect).height }),
                           lineRect.intersection(baseRect).isEmpty == false {
                            let rubyTop = lineRect.minY
                            let rubyBottom = baseRect.minY
                            let rubyHeight = rubyBottom - rubyTop
                            if rubyHeight > 1 {
                                let rubyRect = CGRect(
                                    x: baseRect.minX,
                                    y: rubyTop,
                                    width: baseRect.width,
                                    height: rubyHeight
                                )
                                results.append(rubyRect)
                            }
                        }
                    }
                    // Measured geometry path used; proceed to next ruby range
                    continue
                }
            }

            // Fallback (pre-iOS 16 or if fragments unavailable): synthesize from base union + configured headroom
            var baseUnion: CGRect = .null
            for rect in baseRects {
                var baseRect = rect
                let lineHeight = font?.lineHeight ?? rect.height
                baseRect.origin.y = rect.maxY - lineHeight
                baseRect.size.height = lineHeight
                baseUnion = baseUnion.isNull ? baseRect : baseUnion.union(baseRect)
            }
            guard baseUnion.isNull == false, baseUnion.isEmpty == false else { continue }

            let headroom = max(0, rubyHighlightHeadroom)
            var fullRectInContainer = baseUnion
            fullRectInContainer.origin.y = baseUnion.minY - headroom
            fullRectInContainer.size.height = (baseUnion.maxY - fullRectInContainer.minY)
            guard fullRectInContainer.isNull == false, fullRectInContainer.isEmpty == false else { continue }

            let fallbackRubyHeight = baseUnion.minY - fullRectInContainer.minY
            guard fallbackRubyHeight > 1 else { continue }

            let fallbackRubyRect = CGRect(
                x: fullRectInContainer.minX,
                y: fullRectInContainer.minY,
                width: fullRectInContainer.width,
                height: fallbackRubyHeight
            )
            results.append(fallbackRubyRect)
        }

        return results
    }

    private func textRange(for nsRange: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: nsRange.location),
              let end = position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textRange(from: start, to: end)
    }

    private func selectionHasRuby(for range: NSRange) -> Bool {
        // We intentionally do NOT derive geometry from ruby ranges; we only use this to
        // decide whether a ruby highlight should exist at all.
        guard let attributedText else { return false }
        guard range.location != NSNotFound, range.length > 0 else { return false }
        guard NSMaxRange(range) <= attributedText.length else { return false }

        // Gate on the presence of the actual CoreText ruby attribute so the highlight
        // matches what is rendered (e.g. hidden/removed ruby should not highlight).
        let coreRubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
        var hasRuby = false
        attributedText.enumerateAttribute(coreRubyKey, in: range, options: []) { value, _, stop in
            if value != nil {
                hasRuby = true
                stop.pointee = true
            }
        }
        return hasRuby
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
            clearInspectionHighlight()
            Self.logEvent("Inspect tap ignored: no glyph resolved")
            return
        }

        guard let resolvedIndex = resolvedTextIndex(from: rawIndex) else {
            clearInspectionHighlight()
            Self.logEvent("Inspect tap unresolved: no base character near index=\(rawIndex)")
            return
        }

        guard let selection = spanSelectionContext(forUTF16Index: resolvedIndex) else {
            clearInspectionHighlight()
            Self.logEvent("Inspect tap unresolved: no annotated span contains index=\(resolvedIndex)")
            return
        }

        applyInspectionHighlight(range: selection.highlightRange)
        notifySpanSelection(selection)

        if let details = inspectionDetails(forUTF16Index: resolvedIndex) {
            let charDescription = formattedCharacterDescription(details.character)
            let rangeDescription = "[\(details.utf16Range.location)..<\(NSMaxRange(details.utf16Range))]"
            let scalarsDescription = details.scalars.joined(separator: ", ")
            let indexSummary = rawIndex == resolvedIndex ? "\(resolvedIndex)" : "\(resolvedIndex) (resolved from \(rawIndex))"

            Self.logEvent(
                "Inspect tap char=\(charDescription) utf16Index=\(indexSummary) utf16Range=\(rangeDescription) scalars=[\(scalarsDescription)]"
            )
        } else {
            let highlightDescription = "[\(selection.highlightRange.location)..<\(NSMaxRange(selection.highlightRange))]"
            Self.logEvent("Inspect tap resolved to span range \(highlightDescription) but no character details could be extracted")
        }

        logSpanResolution(for: resolvedIndex)
    }

    private func applyInspectionHighlight(range: NSRange?) {
        selectionHighlightRange = range
    }

    private func clearInspectionHighlight() {
        applyInspectionHighlight(range: nil)
        notifySpanSelection(nil)
    }

    private func notifySpanSelection(_ selection: RubySpanSelection?) {
        spanSelectionHandler?(selection)
    }

    // MARK: - UIContextMenuInteractionDelegate

    // A thin UI affordance that simply routes to the same merge/split handlers used by the dictionary sheet.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard interaction === spanContextMenuInteraction else { return nil }
        guard let stateProvider = contextMenuStateProvider,
              let actionHandler = contextMenuActionHandler,
              let highlightRange = selectionHighlightRange,
              highlightRange.length > 0 else { return nil }
        guard let state = stateProvider(),
              state.canMergeLeft || state.canMergeRight || state.canSplit else { return nil }
        guard let rawIndex = utf16IndexForTap(at: location),
              let resolvedIndex = resolvedTextIndex(from: rawIndex),
              NSLocationInRange(resolvedIndex, highlightRange) else { return nil }
        guard spanSelectionContext(forUTF16Index: resolvedIndex) != nil else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let latestState = self.contextMenuStateProvider?() ?? state
            return self.makeContextMenu(for: latestState, actionHandler: actionHandler)
        }
    }

    private func makeContextMenu(for state: RubyContextMenuState, actionHandler: @escaping (RubyContextMenuAction) -> Void) -> UIMenu? {
        var actions: [UIAction] = []

        let mergeLeft = UIAction(title: "Merge Left", image: UIImage(systemName: "arrow.left.to.line")) { _ in
            actionHandler(.mergeLeft)
        }
        mergeLeft.attributes = state.canMergeLeft ? [] : [.disabled]
        actions.append(mergeLeft)

        let mergeRight = UIAction(title: "Merge Right", image: UIImage(systemName: "arrow.right.to.line")) { _ in
            actionHandler(.mergeRight)
        }
        mergeRight.attributes = state.canMergeRight ? [] : [.disabled]
        actions.append(mergeRight)

        let split = UIAction(title: "Split", image: UIImage(systemName: "scissors")) { _ in
            actionHandler(.split)
        }
        split.attributes = state.canSplit ? [] : [.disabled]
        actions.append(split)

        return UIMenu(title: "", children: actions)
    }

    private func utf16IndexForTap(at point: CGPoint) -> Int? {
        guard let attributedLength = attributedText?.length, attributedLength > 0 else { return nil }

        if let directRange = characterRange(at: point) {
            let offset = offset(from: beginningOfDocument, to: directRange.start)
            guard offset >= 0, offset < attributedLength else { return nil }
            return offset
        }

        guard pointHitsRenderedText(point, attributedLength: attributedLength) else { return nil }
        guard let textRange = textRangeNearPoint(point) else { return nil }
        let offset = offset(from: beginningOfDocument, to: textRange.start)
        guard offset >= 0, offset < attributedLength else { return nil }

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
        guard let backingString = attributedText?.string, backingString.isEmpty == false else { return nil }
        let utf16View = backingString.utf16
        let length = utf16View.count
        guard length > 0 else { return nil }
        let clamped = max(0, min(candidate, length - 1))
        guard let utf16Position = utf16View.index(utf16View.startIndex, offsetBy: clamped, limitedBy: utf16View.endIndex),
              let stringIndex = String.Index(utf16Position, within: backingString) else {
            return nil
        }

        if isInspectableCharacter(backingString[stringIndex]) {
            return clamped
        }

        if let previous = inspectableIndex(before: stringIndex, in: backingString),
           let offset = utf16Offset(of: previous, in: backingString) {
            return offset
        }

        if let next = inspectableIndex(after: stringIndex, in: backingString),
           let offset = utf16Offset(of: next, in: backingString) {
            return offset
        }

        return nil
    }

    private func inspectableIndex(before index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            if isInspectableCharacter(text[cursor]) {
                return cursor
            }
        }
        return nil
    }

    private func inspectableIndex(after index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            guard next < text.endIndex else { break }
            if isInspectableCharacter(text[next]) {
                return next
            }
            cursor = next
        }
        return nil
    }

    private func utf16Offset(of index: String.Index, in text: String) -> Int? {
        guard let utf16Position = index.samePosition(in: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Position)
    }

    private func isInspectableCharacter(_ character: Character) -> Bool {
        character.isNewline == false
    }

    private func pointHitsRenderedText(_ point: CGPoint, attributedLength: Int) -> Bool {
        guard attributedLength > 0 else { return false }
        let fullRange = NSRange(location: 0, length: attributedLength)
        guard let uiRange = textRange(for: fullRange) else { return false }
        let rects = selectionRects(for: uiRange)
            .map { $0.rect }
            .filter { $0.isNull == false && $0.isEmpty == false }
        return rects.contains(where: { $0.contains(point) })
    }

    private func spanSelectionContext(forUTF16Index index: Int) -> RubySpanSelection? {
        guard let (spanIndex, span) = annotatedSpans.spanContext(containingUTF16Index: index) else { return nil }
        let spanRange = span.span.range
        guard spanRange.location != NSNotFound, spanRange.length > 0 else { return nil }
        return RubySpanSelection(spanIndex: spanIndex, annotatedSpan: span, highlightRange: spanRange)
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

    private func logSpanResolution(for index: Int) {
        guard let span = annotatedSpans.spanContainingUTF16Index(index) else {
            Self.logEvent("Inspect tap span unresolved: no annotated span contains index=\(index)")
            return
        }
        let spanRange = span.span.range
        let spanSurfaceDescription = span.span.surface.debugDescription
        let rangeDescription = "[\(spanRange.location)..<\(NSMaxRange(spanRange))]"
        Self.logEvent("Inspect tap span surface=\(spanSurfaceDescription) range=\(rangeDescription)")
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

extension Collection where Element == AnnotatedSpan {
    func spanContainingUTF16Index(_ index: Int) -> AnnotatedSpan? {
        guard isEmpty == false, index >= 0 else { return nil }
        for span in self {
            let range = span.span.range
            guard range.location != NSNotFound else { continue }
            if NSLocationInRange(index, range) {
                return span
            }
        }
        return nil
    }

    func spanContext(containingUTF16Index index: Int) -> (Int, AnnotatedSpan)? {
        guard isEmpty == false, index >= 0 else { return nil }
        for (offset, span) in enumerated() {
            let range = span.span.range
            guard range.location != NSNotFound else { continue }
            if NSLocationInRange(index, range) {
                return (offset, span)
            }
        }
        return nil
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

