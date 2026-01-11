import SwiftUI
import UIKit
#if DEBUG
import ObjectiveC
#endif

extension NSAttributedString.Key {
    static let rubyAnnotation = NSAttributedString.Key("RubyAnnotation")
    static let rubyReadingText = NSAttributedString.Key("RubyReadingText")
    static let rubyReadingFontSize = NSAttributedString.Key("RubyReadingFontSize")
}

enum RubyAnnotationVisibility {
    case visible
    case hiddenKeepMetrics
    case removed
}

struct RubySpanSelection {
    let tokenIndex: Int
    let semanticSpan: SemanticSpan
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
    var isScrollEnabled: Bool = false
    var allowSystemTextSelection: Bool = true
    var wrapLines: Bool = true
    var horizontalScrollEnabled: Bool = false
    var tokenOverlays: [TokenOverlay] = []
    var semanticSpans: [SemanticSpan] = []
    var selectedRange: NSRange? = nil
    var customizedRanges: [NSRange] = []
    var enableTapInspection: Bool = true
    var enableDragSelection: Bool = false
    var onDragSelectionBegan: (() -> Void)? = nil
    var onDragSelectionEnded: ((NSRange) -> Void)? = nil
    var onCharacterTap: ((Int) -> Void)? = nil
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
        textView.isSelectable = allowSystemTextSelection
        textView.isScrollEnabled = isScrollEnabled
        textView.wrapLines = wrapLines
        textView.horizontalScrollEnabled = horizontalScrollEnabled
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.maximumNumberOfLines = 0
        textView.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        if wrapLines == false {
            // Avoid an initial wrapped layout before SwiftUI's first `sizeThatFits` pass.
            textView.textContainer.size = CGSize(width: 20000, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.textContainerInset = textInsets
        textView.clipsToBounds = true
        textView.layer.masksToBounds = true
        textView.tintColor = .systemBlue
        textView.font = UIFont.systemFont(ofSize: fontSize)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.isTapInspectionEnabled = enableTapInspection
        textView.isDragSelectionEnabled = enableDragSelection
        textView.dragSelectionBeganHandler = onDragSelectionBegan
        textView.dragSelectionEndedHandler = onDragSelectionEnded
        textView.spanSelectionHandler = onSpanSelection
        textView.characterTapHandler = onCharacterTap
        textView.contextMenuStateProvider = contextMenuStateProvider
        textView.contextMenuActionHandler = onContextMenuAction
        textView.delegate = context.coordinator

        if allowSystemTextSelection == false {
            textView.selectedRange = NSRange(location: 0, length: 0)
            textView.resignFirstResponder()
            if #available(iOS 11.0, *) {
                textView.textDragInteraction?.isEnabled = false
            }
        }
        return textView
    }

    func updateUIView(_ uiView: TokenOverlayTextView, context: Context) {
        // INVESTIGATION NOTES (2026-01-04)
        // This method runs on the main thread as part of SwiftUI/UIViewRepresentable updates.
        // Potential UI-jitter contributors here:
        // - `requiredVerticalHeadroomForRuby(in: attributed, ...)` can scan attributed runs (potentially O(text length)).
        // - Building `renderKey` hashes iterates all token overlays + customized ranges (O(k)).
        // - When `shouldReapplyAttributedText` is true, this allocates a new NSMutableAttributedString and reapplies multiple
        //   attributes across the full range (O(text length)) and also applies overlay/highlight attribute passes.
        // Any increases in how often `updateUIView` is triggered (e.g., selection/highlight changes) will amplify this cost.
        uiView.font = UIFont.systemFont(ofSize: fontSize)
        uiView.tintColor = .systemBlue
        uiView.rubyAnnotationVisibility = annotationVisibility
        uiView.isEditable = false
        uiView.isSelectable = allowSystemTextSelection
        uiView.isScrollEnabled = isScrollEnabled
        uiView.wrapLines = wrapLines
        uiView.horizontalScrollEnabled = horizontalScrollEnabled
        uiView.textContainer.widthTracksTextView = false
        uiView.textContainer.maximumNumberOfLines = 0
        uiView.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        if wrapLines == false, uiView.textContainer.size.width < 20000 {
            uiView.textContainer.size = CGSize(width: 20000, height: CGFloat.greatestFiniteMagnitude)
        }

        if allowSystemTextSelection == false {
            uiView.selectedRange = NSRange(location: 0, length: 0)
            uiView.resignFirstResponder()
            if #available(iOS 11.0, *) {
                uiView.textDragInteraction?.isEnabled = false
            }
        } else {
            if #available(iOS 11.0, *) {
                uiView.textDragInteraction?.isEnabled = true
            }
        }

        // Gap between ruby and headword. Keep it small and stable so ruby feels anchored.
        // (Previously this was a bit too large, making ruby feel "detached".)
        let rubyBaselineGap = max(0.5, extraGap * 0.12)

        // Compute extra headroom for ruby above the baseline.
        // We reserve enough vertical space for the *largest* ruby run so that
        // changing furigana size doesn't make ruby appear to "grow downward".
        let defaultRubyFontSize = max(1, fontSize * 0.6)
        let rubyHeadroom = max(
            0,
            max(
                fontSize * 0.6 + extraGap,
                RubyText.requiredVerticalHeadroomForRuby(
                    in: attributed,
                    baseFont: UIFont.systemFont(ofSize: fontSize),
                    defaultRubyFontSize: defaultRubyFontSize,
                    rubyBaselineGap: rubyBaselineGap
                )
            )
        )

        var insets = textInsets
        insets.top = max(insets.top, rubyHeadroom)
        uiView.rubyHighlightHeadroom = rubyHeadroom
        uiView.rubyBaselineGap = rubyBaselineGap

        var renderHasher = Hasher()
        renderHasher.combine(ObjectIdentifier(attributed))
        renderHasher.combine(attributed.length)
        renderHasher.combine(Int((fontSize * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((lineHeightMultiple * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((extraGap * 1000).rounded(.toNearestOrEven)))
        switch annotationVisibility {
        case .visible: renderHasher.combine(1)
        case .hiddenKeepMetrics: renderHasher.combine(2)
        case .removed: renderHasher.combine(3)
        }
        renderHasher.combine(Int((insets.top * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((insets.left * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((insets.bottom * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((insets.right * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(tokenOverlays.count)
        for o in tokenOverlays {
            renderHasher.combine(o.range.location)
            renderHasher.combine(o.range.length)
            renderHasher.combine(o.color.hash)
        }
        renderHasher.combine(customizedRanges.count)
        for r in customizedRanges {
            renderHasher.combine(r.location)
            renderHasher.combine(r.length)
        }
        let renderKey = renderHasher.finalize()
        let shouldReapplyAttributedText = (uiView.lastAppliedRenderKey != renderKey) || (uiView.attributedText == nil)

        if shouldReapplyAttributedText {

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
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

        // Removed the computation and adjustment of horizontal insets for ruby overhang.
        // We now simply assign insets directly without modifying left/right based on overhang.
        uiView.textContainerInset = insets

        let processed = RubyText.applyAnnotationVisibility(annotationVisibility, to: mutable)

        uiView.applyAttributedText(processed)
        uiView.lastAppliedRenderKey = renderKey
        }
        uiView.semanticSpans = semanticSpans
        uiView.selectionHighlightRange = selectedRange
        uiView.isTapInspectionEnabled = enableTapInspection
        uiView.isDragSelectionEnabled = enableDragSelection
        uiView.dragSelectionBeganHandler = onDragSelectionBegan
        uiView.dragSelectionEndedHandler = onDragSelectionEnded
        uiView.spanSelectionHandler = onSpanSelection
        uiView.characterTapHandler = onCharacterTap
        uiView.contextMenuStateProvider = contextMenuStateProvider
        uiView.contextMenuActionHandler = onContextMenuAction

        context.coordinator.stateProvider = contextMenuStateProvider
        context.coordinator.actionHandler = onContextMenuAction

        // Help the view expand vertically rather than compress
        uiView.setContentCompressionResistancePriority(.required, for: .vertical)
        uiView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        uiView.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TokenOverlayTextView, context: Context) -> CGSize {
        let proposedWidth = proposal.width

        // Prefer a conservative, narrow fallback width on first measure to avoid under-measuring
        // (which can clip wrapped lines until SwiftUI re-measures). Avoid using screen width here.
        let conservativeFallbackWidth: CGFloat = 320

        let boundedFallbackWidth: CGFloat = {
            if let w = uiView.superview?.bounds.width, w.isFinite, w > 0 {
                return w
            }
            let w = uiView.bounds.width
            if w.isFinite, w > 0 {
                return w
            }
            return conservativeFallbackWidth
        }()

        let rawWidth = (proposedWidth ?? boundedFallbackWidth)
        // Do not clamp to screen width; use a conservative width to ensure we never under-measure height.
        let baseWidth = max(1, rawWidth)

        // Snap widths to pixel boundaries to avoid sub-pixel wrapping differences.
        let scale: CGFloat = {
            if let s = uiView.window?.windowScene?.screen.scale, s > 0 { return s }
            let traitScale = uiView.traitCollection.displayScale
            return traitScale > 0 ? traitScale : 2.0
        }()
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        let snappedBaseWidth = snap(baseWidth)

        // Ensure TextKit measures with the same constrained width we'll draw with.
        // Do NOT mutate view geometry (e.g. `bounds`) here; only configure TextKit.
        let inset = uiView.textContainerInset
        var targetWidth = max(0, snap(baseWidth - inset.left - inset.right))
        if wrapLines == false {
            // No internal wrapping: give TextKit a large container width so content can scroll horizontally.
            targetWidth = max(targetWidth, 20000)
        }

        uiView.lastMeasuredBoundsWidth = snappedBaseWidth
        uiView.lastMeasuredTextContainerWidth = targetWidth
        if abs(uiView.textContainer.size.width - targetWidth) > 0.5 {
            uiView.textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
        }

        let shouldLog = (proposedWidth == nil) || abs(uiView.bounds.width - snappedBaseWidth) > 0.5
        if shouldLog {
            let message = String(
                format: "MEASURE sizeThatFits proposalWidth=%@ baseWidth=%.2f boundsWidth=%.2f insetL=%.2f insetR=%.2f padding=%.2f containerW=%.2f",
                String(describing: proposedWidth),
                snappedBaseWidth,
                uiView.bounds.width,
                inset.left,
                inset.right,
                uiView.textContainer.lineFragmentPadding,
                uiView.textContainer.size.width
            )
            CustomLogger.shared.debug(message)
        }

        let targetSize = CGSize(width: snappedBaseWidth, height: CGFloat.greatestFiniteMagnitude)
        let measured = uiView.sizeThatFits(targetSize)
        let measuredHeight = measured.height > 0 ? measured.height : targetSize.height
        return CGSize(width: snappedBaseWidth, height: measuredHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var stateProvider: (() -> RubyContextMenuState?)?
        var actionHandler: ((RubyContextMenuAction) -> Void)?

        @available(iOS 16.0, *)
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            // Query the current state to decide availability
            let state = stateProvider?()

            var actions: [UIAction] = []

            let mergeLeft = UIAction(title: "Merge Left", image: UIImage(systemName: "arrow.left.to.line")) { [weak self] _ in
                self?.actionHandler?(.mergeLeft)
            }
            mergeLeft.attributes = (state?.canMergeLeft ?? false) ? [] : [.disabled]
            actions.append(mergeLeft)

            let mergeRight = UIAction(title: "Merge Right", image: UIImage(systemName: "arrow.right.to.line")) { [weak self] _ in
                self?.actionHandler?(.mergeRight)
            }
            mergeRight.attributes = (state?.canMergeRight ?? false) ? [] : [.disabled]
            actions.append(mergeRight)

            let split = UIAction(title: "Split", image: UIImage(systemName: "scissors")) { [weak self] _ in
                self?.actionHandler?(.split)
            }
            split.attributes = (state?.canSplit ?? false) ? [] : [.disabled]
            actions.append(split)

            let custom = UIMenu(title: "", options: .displayInline, children: actions)
            // Preserve system actions like Look Up by appending suggestedActions
            return UIMenu(children: [custom] + suggestedActions)
        }

        @available(iOS 16.0, *)
        func textView(_ textView: UITextView,
                      targetRectForEditMenuForTextIn range: NSRange) -> CGRect {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let tr = textView.textRange(from: start, to: end) else {
                return .zero
            }
            return textView.firstRect(for: tr)
        }
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
            // Ruby is drawn manually from `.rubyReadingText`. Keep attributes to preserve
            // selection + layout behavior; drawing is gated by the view-level visibility flag.
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

    private static func removeAnnotationRuns(from attributedString: NSMutableAttributedString) -> NSAttributedString {
        let ranges = annotationRanges(in: attributedString)
        guard ranges.isEmpty == false else { return attributedString }
        for range in ranges {
            attributedString.removeAttribute(coreTextRubyAttribute, range: range)
            attributedString.removeAttribute(.rubyAnnotation, range: range)
            attributedString.removeAttribute(.rubyReadingText, range: range)
            attributedString.removeAttribute(.rubyReadingFontSize, range: range)
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

    /// Computes the additional vertical headroom required to accommodate the tallest ruby reading above the base line.
    /// Falls back to a conservative estimate based on `defaultRubyFontSize` and `rubyBaselineGap` when no ruby is present.
    static func requiredVerticalHeadroomForRuby(
        in attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat,
        rubyBaselineGap: CGFloat
    ) -> CGFloat {
        guard attributed.length > 0 else { return max(0, defaultRubyFontSize + rubyBaselineGap) }
        let full = NSRange(location: 0, length: attributed.length)
        var maxRubySize: CGFloat = 0
        attributed.enumerateAttribute(.rubyReadingFontSize, in: full, options: []) { value, _, _ in
            if let num = value as? NSNumber {
                maxRubySize = max(maxRubySize, CGFloat(max(1.0, num.doubleValue)))
            } else if let cg = value as? CGFloat {
                maxRubySize = max(maxRubySize, max(1.0, cg))
            } else if let dbl = value as? Double {
                maxRubySize = max(maxRubySize, CGFloat(max(1.0, dbl)))
            }
        }
        if maxRubySize <= 0 {
            maxRubySize = max(1.0, defaultRubyFontSize)
        }
        // Reserve the ruby font height plus a small gap to visually separate from the base glyphs.
        return max(0, maxRubySize + rubyBaselineGap)
    }

    /// Computes a symmetric horizontal inset to prevent ruby from overhanging and being clipped at the edges.
    /// Uses the maximum ruby size found in the attributed string as a heuristic; otherwise falls back to `defaultRubyFontSize * 0.25`.
    static func requiredHorizontalInsetForRubyOverhang(
        in attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat
    ) -> CGFloat {
        guard attributed.length > 0 else { return max(0, defaultRubyFontSize * 0.25) }
        let full = NSRange(location: 0, length: attributed.length)
        var maxRubySize: CGFloat = 0
        attributed.enumerateAttribute(.rubyReadingFontSize, in: full, options: []) { value, _, _ in
            if let num = value as? NSNumber {
                maxRubySize = max(maxRubySize, CGFloat(max(1.0, num.doubleValue)))
            } else if let cg = value as? CGFloat {
                maxRubySize = max(maxRubySize, max(1.0, cg))
            } else if let dbl = value as? Double {
                maxRubySize = max(maxRubySize, CGFloat(max(1.0, dbl)))
            }
        }
        if maxRubySize <= 0 {
            maxRubySize = max(1.0, defaultRubyFontSize)
        }
        // Heuristic: allow a small fraction of the ruby size as overhang inset on each side.
        return max(0, maxRubySize * 0.25)
    }
}

final class TokenOverlayTextView: UITextView, UIContextMenuInteractionDelegate {
    // NOTE: Avoid TextKit 1 entry points (`layoutManager`, `textStorage`, `glyphRange(...)`, etc.).
    // Geometry for highlights + ruby anchoring is derived via TextKit 2 (`textLayoutManager`)
    // with `selectionRects(for:)` as a UI-safe fallback.

    var semanticSpans: [SemanticSpan] = []

    // Cache a lightweight signature of the last fully applied attributed rendering.
    // This helps avoid reassigning `attributedText` on highlight-only updates.
    fileprivate var lastAppliedRenderKey: Int? = nil

    // Vertical gap between the headword and ruby text.
    var rubyBaselineGap: CGFloat = 1.0

    var rubyAnnotationVisibility: RubyAnnotationVisibility = .visible {
        didSet {
            guard oldValue != rubyAnnotationVisibility else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }
    }

    // SwiftUI measurement uses `sizeThatFits`. Record the width we measured at so we can
    // request a re-measure if our final bounds width changes.
    fileprivate var lastMeasuredBoundsWidth: CGFloat = 0
    fileprivate var lastMeasuredTextContainerWidth: CGFloat = 0

    var selectionHighlightRange: NSRange? {
        didSet {
            guard oldValue != selectionHighlightRange else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            CustomLogger.shared.debug("selectionHighlightRange didSet -> setNeedsLayout (range=\(String(describing: selectionHighlightRange)))")
        }
    }

    var selectionHighlightInsets: UIEdgeInsets = .zero {
        didSet {
            guard oldValue != selectionHighlightInsets else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            CustomLogger.shared.debug(String(format: "selectionHighlightInsets didSet -> setNeedsLayout (top=%.2f left=%.2f bottom=%.2f right=%.2f)", selectionHighlightInsets.top, selectionHighlightInsets.left, selectionHighlightInsets.bottom, selectionHighlightInsets.right))
        }
    }

    var isTapInspectionEnabled: Bool = true {
        didSet {
            guard oldValue != isTapInspectionEnabled else { return }
            updateInspectionGestureState()
        }
    }

    var wrapLines: Bool = true {
        didSet {
            guard oldValue != wrapLines else { return }
            applyStableTextContainerConfig()
            // When toggling from horizontal-scroll mode (very wide container) back to wrap,
            // force SwiftUI to re-measure so `sizeThatFits` can clamp the container width.
            lastMeasuredBoundsWidth = 0
            lastMeasuredTextContainerWidth = 0
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    var horizontalScrollEnabled: Bool = false {
        didSet {
            guard oldValue != horizontalScrollEnabled else { return }
            updateHorizontalScrollConfig()
            setNeedsLayout()
        }
    }

    var isDragSelectionEnabled: Bool = false {
        didSet {
            guard oldValue != isDragSelectionEnabled else { return }
            updateDragSelectionGestureState()
        }
    }

    var spanSelectionHandler: ((RubySpanSelection?) -> Void)? = nil
    var characterTapHandler: ((Int) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var contextMenuActionHandler: ((RubyContextMenuAction) -> Void)? = nil

    var dragSelectionBeganHandler: (() -> Void)? = nil
    var dragSelectionEndedHandler: ((NSRange) -> Void)? = nil

    private lazy var inspectionTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInspectionTap(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    private lazy var spanContextMenuInteraction = UIContextMenuInteraction(delegate: self)

    private lazy var dragSelectionRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleDragSelectionLongPress(_:)))
        recognizer.minimumPressDuration = 0.15
        recognizer.allowableMovement = 10
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    private var dragSelectionAnchorUTF16: Int? = nil
    private var dragSelectionActive: Bool = false

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
            CustomLogger.shared.debug(String(format: "rubyHighlightHeadroom didSet -> setNeedsLayout (headroom=%.2f)", rubyHighlightHeadroom))
            invalidateIntrinsicContentSize()
        }
    }

    private var needsHighlightUpdate: Bool = false

    private struct RubyRun {
        let range: NSRange
        let reading: String
        let fontSize: CGFloat
        let color: UIColor
    }

    private var cachedRubyRuns: [RubyRun] = []
    private var scrollRedrawScheduled: Bool = false

    private static let verboseRubyLoggingEnabled: Bool = {
        ProcessInfo.processInfo.environment["RUBY_TRACE"] == "1"
    }()

    private var lastTextContainerIdentity: ObjectIdentifier? = nil

    override var contentOffset: CGPoint {
        didSet {
            // Ruby readings are custom-drawn in `draw(_:)`. When this view is scrollable,
            // UIKit can scroll cached text content without re-invoking our draw pass,
            // which makes ruby appear "stuck" while the text scrolls. Explicitly request
            // a redraw on scroll so ruby stays aligned to glyph positions.
            guard isScrollEnabled else { return }
            guard oldValue != contentOffset else { return }
            scheduleScrollRedraw()
        }
    }

    private func scheduleScrollRedraw() {
        // Scroll events can arrive very frequently. Coalesce redraws to once per runloop
        // tick so ruby/highlights stay responsive without flooding `draw(_:)`.
        guard scrollRedrawScheduled == false else { return }
        scrollRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollRedrawScheduled = false

            // IMPORTANT: highlight paths are stored in view coordinates.
            // When the view scrolls, UIKit can move cached text without giving us a new layout pass,
            // which leaves the highlight path “stuck” at its old Y position.
            if self.selectionHighlightRange != nil {
                self.updateSelectionHighlightPath()
            } else {
                self.setNeedsDisplay()
            }
        }
    }

    private func applyStableTextContainerConfig() {
        // For SwiftUI measurement-driven wrapping we must control the container width
        // (set in `RubyText.sizeThatFits`). If UIKit swaps/rebuilds the container, these
        // properties can revert to defaults.
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping

        if wrapLines {
            // If we previously disabled wrapping, we may still have an extremely wide container.
            // In that case, `lineBreakMode = .byWordWrapping` won't actually wrap until the
            // container width is constrained. SwiftUI should correct this via `sizeThatFits`,
            // but shrink immediately to the current bounds when possible.
            if textContainer.size.width > 10000 {
                let inset = textContainerInset
                let targetWidth = max(1, bounds.width - inset.left - inset.right)
                if targetWidth.isFinite, targetWidth > 1 {
                    textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
                } else {
                    // Conservative fallback; SwiftUI measurement will refine this.
                    textContainer.size = CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
                }
            }
        } else {
            if textContainer.size.width < 20000 {
                textContainer.size = CGSize(width: 20000, height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }

    private func updateHorizontalScrollConfig() {
        alwaysBounceHorizontal = horizontalScrollEnabled
        showsHorizontalScrollIndicator = horizontalScrollEnabled
        // Keep vertical scroll behavior as-is; the view can be vertically scrollable regardless.
    }

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
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        textContainerInset = .zero
        clipsToBounds = true
        layer.masksToBounds = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        lastTextContainerIdentity = ObjectIdentifier(textContainer)
        applyStableTextContainerConfig()
        updateHorizontalScrollConfig()
        updateInspectionGestureState()
        updateDragSelectionGestureState()
        addInteraction(spanContextMenuInteraction)
        needsHighlightUpdate = true
    }

    override var canBecomeFirstResponder: Bool { true }

    override var intrinsicContentSize: CGSize {
        // Do not advertise an intrinsic width based on content; that can cause SwiftUI
        // to size this view wide enough to fit a single long line (no wrapping).
        let size = super.intrinsicContentSize
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // UIKit may replace/reinitialize the underlying text container during runtime.
        // If that happens, reapply our required container settings immediately.
        let currentIdentity = ObjectIdentifier(textContainer)
        if lastTextContainerIdentity != currentIdentity {
            lastTextContainerIdentity = currentIdentity
            applyStableTextContainerConfig()
        } else if textContainer.widthTracksTextView != false {
            applyStableTextContainerConfig()
        }

#if DEBUG
        do {
            let b = bounds
            let tcSize = textContainer.size
            let csH = contentSize.height
            let scroll = isScrollEnabled
            let tracks = textContainer.widthTracksTextView
            let tcID = ObjectIdentifier(textContainer).hashValue
            let vis: String = {
                switch rubyAnnotationVisibility {
                case .visible: return "visible"
                case .hiddenKeepMetrics: return "hiddenKeepMetrics"
                case .removed: return "removed"
                }
            }()

            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug( String( format: "PASS layoutSubviews bounds=%.2fx%.2f textContainer=%.2fx%.2f contentSizeH=%.2f scroll=%@ tracksWidth=%@ tcID=%d ruby=%@", b.width, b.height, tcSize.width, tcSize.height, csH, scroll ? "true" : "false", tracks ? "true" : "false", tcID, vis ) )
            }
        }
#endif

        // A) Measurement correctness: do not mutate `textContainer.size.width` here.
        // If our final width differs from the measured width, ask SwiftUI to re-measure;
        // `sizeThatFits` is the only place that clamps the wrapping width.
        let inset = textContainerInset
        let currentTargetWidth = max(0, bounds.width - inset.left - inset.right)
        let boundsMismatch = lastMeasuredBoundsWidth > 0 && abs(bounds.width - lastMeasuredBoundsWidth) > 0.5
        let containerMismatch = lastMeasuredTextContainerWidth > 0 && abs(currentTargetWidth - lastMeasuredTextContainerWidth) > 0.5
        if boundsMismatch || containerMismatch {
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug( String( format: "LAYOUT layoutSubviews boundsW=%.2f measuredW=%.2f insetL=%.2f insetR=%.2f padding=%.2f currentTargetW=%.2f measuredTargetW=%.2f containerW=%.2f", bounds.width, lastMeasuredBoundsWidth, inset.left, inset.right, textContainer.lineFragmentPadding, currentTargetWidth, lastMeasuredTextContainerWidth, textContainer.size.width ) )
            }
            invalidateIntrinsicContentSize()
        }

        if Self.verboseRubyLoggingEnabled {
            CustomLogger.shared.debug("layoutSubviews: needsHighlightUpdate=\(needsHighlightUpdate)")
        }
        if needsHighlightUpdate {
            updateSelectionHighlightPath()
            needsHighlightUpdate = false
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("layoutSubviews: performed highlight update")
            }
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

        if rubyAnnotationVisibility == .visible {
            drawRubyReadings()
        }
    }

    private func drawRubyReadings() {
        guard cachedRubyRuns.isEmpty == false else { return }

        // Precompute visible line typographic bounds once per draw pass.
        // This keeps ruby anchored correctly even when line spacing/leading is present,
        // and avoids per-run fragment enumeration.
        let visibleLineRectsInView = textKit2LineTypographicRectsInViewCoordinates(visibleOnly: true)

        // During fast scrolling, drawing ruby for the entire document is unnecessary and expensive.
        // Restrict work to runs that intersect the visible UTF-16 range (plus a small margin).
        let visibleRange: NSRange? = visibleUTF16Range().map { expandRange($0, by: 512) }

        for run in cachedRubyRuns {
            if let visibleRange {
                let intersection = NSIntersectionRange(run.range, visibleRange)
                if intersection.length <= 0 { continue }
            }

            // Use TextKit glyph geometry instead of `selectionRects(for:)`.
            // `selectionRects` can include extra vertical padding, which makes ruby
            // appear too low (behind the headword) when we anchor it to those rects.
            let baseRects = self.rubyAnchorRects(in: run.range, lineRectsInView: visibleLineRectsInView)
            guard baseRects.isEmpty == false else { continue }

            let unions = self.unionRectsByLine(baseRects)
            guard unions.isEmpty == false else { continue }

            let rubyFont = UIFont.systemFont(ofSize: run.fontSize)
            let baseColor = run.color
            let attrs: [NSAttributedString.Key: Any] = [
                .font: rubyFont,
                .foregroundColor: baseColor
            ]

            for baseUnion in unions {
                let headroom = max(0, self.rubyHighlightHeadroom)
                guard headroom > 0 else { continue }

                let rubyRect = CGRect(
                    x: baseUnion.minX,
                    y: baseUnion.minY - headroom,
                    width: baseUnion.width,
                    height: headroom
                )

                let size = (run.reading as NSString).size(withAttributes: attrs)
                let x = rubyRect.midX - (size.width / 2.0)

                // Bottom-anchor ruby near the headword: keep a small consistent gap and let
                // the top edge move when ruby size changes.
                let gap = max(1.0, self.rubyBaselineGap)
                let y = (baseUnion.minY - gap) - size.height
                (run.reading as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            }
        }
    }

    private func visibleUTF16Range() -> NSRange? {
        guard let attributedText, attributedText.length > 0 else { return nil }
        let maxLen = attributedText.length

        // Use `closestPosition(to:)` so we don't need TextKit 1 glyph APIs.
        let x = max(1, bounds.minX + 4)
        let topPoint = CGPoint(x: x, y: bounds.minY + 1)
        let bottomPoint = CGPoint(x: x, y: bounds.maxY - 1)

        guard let topPos = closestPosition(to: topPoint),
              let bottomPos = closestPosition(to: bottomPoint) else {
            return nil
        }

        let a = offset(from: beginningOfDocument, to: topPos)
        let b = offset(from: beginningOfDocument, to: bottomPos)
        guard a != NSNotFound, b != NSNotFound else { return nil }

        let start = max(0, min(a, b))
        let end = min(maxLen, max(a, b) + 1)
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private func expandRange(_ range: NSRange, by delta: Int) -> NSRange {
        guard let attributedText else { return range }
        let maxLen = attributedText.length
        guard maxLen > 0 else { return range }

        let start = max(0, range.location - delta)
        let end = min(maxLen, NSMaxRange(range) + delta)
        guard end > start else { return range }
        return NSRange(location: start, length: end - start)
    }

    private func rubyAnchorRects(in characterRange: NSRange) -> [CGRect] {
        rubyAnchorRects(in: characterRange, lineRectsInView: nil)
    }

    private func rubyAnchorRects(in characterRange: NSRange, lineRectsInView: [CGRect]?) -> [CGRect] {
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return [] }
        guard let attributedText, NSMaxRange(characterRange) <= attributedText.length else { return [] }
        guard let uiRange = textRange(for: characterRange) else { return [] }

        layoutIfNeeded()

        let selectionRectsInView = selectionRects(for: uiRange)
            .map { $0.rect }
            .filter { $0.isNull == false && $0.isEmpty == false }
        guard selectionRectsInView.isEmpty == false else { return [] }

        // When possible, clamp each selection rect to the line's typographic bounds.
        // This avoids using `font.lineHeight` and avoids drifting when paragraph line spacing is present.
        let candidates = lineRectsInView ?? textKit2LineTypographicRectsInViewCoordinates(visibleOnly: true)
        guard candidates.isEmpty == false else { return selectionRectsInView }

        return selectionRectsInView.map { sel in
            guard let bestLine = bestMatchingLineRect(for: sel, candidates: candidates) else { return sel }
            var r = sel
            r.origin.y = bestLine.minY
            r.size.height = bestLine.height
            return r
        }
    }

    private func unionRectsByLine(_ rects: [CGRect]) -> [CGRect] {
        let sorted = rects.sorted {
            if abs($0.midY - $1.midY) > 0.5 {
                return $0.midY < $1.midY
            }
            return $0.minX < $1.minX
        }

        var unions: [CGRect] = []
        var current: CGRect? = nil
        let yTolerance: CGFloat = 1.0

        for rect in sorted {
            if var cur = current {
                if abs(cur.midY - rect.midY) <= yTolerance {
                    cur = cur.union(rect)
                    current = cur
                } else {
                    unions.append(cur)
                    current = rect
                }
            } else {
                current = rect
            }
        }

        if let cur = current {
            unions.append(cur)
        }
        return unions
    }

    func applyAttributedText(_ text: NSAttributedString) {
        if let current = attributedText, current.isEqual(to: text) {
            // No change; avoid resetting attributedText which would dismiss menus.
            return
        }
        let savedOffset = contentOffset
        let wasFirstResponder = isFirstResponder
        let oldSelectedRange = selectedRange
        attributedText = text
        rebuildRubyRunCache(from: text)
        if wasFirstResponder {
            _ = becomeFirstResponder()
            let newLength = attributedText?.length ?? 0
            if oldSelectedRange.location != NSNotFound, NSMaxRange(oldSelectedRange) <= newLength {
                selectedRange = oldSelectedRange
            }
        }

        if isScrollEnabled {
            // Setting attributedText can snap to the top; restore prior offset.
            layoutIfNeeded()

            let minY = -adjustedContentInset.top
            let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
            let clampedY = min(max(savedOffset.y, minY), maxY)
            let clamped = CGPoint(x: savedOffset.x, y: clampedY)
            if (clamped.y - contentOffset.y).magnitude > 0.5 {
                setContentOffset(clamped, animated: false)
            }
        }
        needsHighlightUpdate = true
        setNeedsLayout()
        // Attribute-only changes (e.g. token foreground colors) may not trigger a repaint
        // if layout metrics are unchanged. Ruby drawing depends on the attributed runs, so
        // ensure we redraw whenever the attributed text changes.
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
        CustomLogger.shared.debug("applyAttributedText -> setNeedsLayout")
    }

    private func rebuildRubyRunCache(from text: NSAttributedString) {
        guard text.length > 0 else {
            cachedRubyRuns = []
            return
        }

        let fullRange = NSRange(location: 0, length: text.length)
        var runs: [RubyRun] = []
        runs.reserveCapacity(64)

        let baseFontSize = font?.pointSize ?? 17.0

        text.enumerateAttribute(.rubyReadingText, in: fullRange, options: []) { value, range, _ in
            guard let reading = value as? String, reading.isEmpty == false else { return }
            guard range.location != NSNotFound, range.length > 0 else { return }
            guard NSMaxRange(range) <= text.length else { return }

            let rubyFontSize: CGFloat
            if let stored = text.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? Double {
                rubyFontSize = CGFloat(max(1.0, stored))
            } else if let stored = text.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? CGFloat {
                rubyFontSize = max(1.0, stored)
            } else if let stored = text.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? NSNumber {
                rubyFontSize = CGFloat(max(1.0, stored.doubleValue))
            } else {
                rubyFontSize = CGFloat(max(1.0, baseFontSize * 0.6))
            }

            let color = (text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor) ?? UIColor.label
            runs.append(RubyRun(range: range, reading: reading, fontSize: rubyFontSize, color: color))
        }

        cachedRubyRuns = runs
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
        // IMPORTANT: Do not rely solely on `selectionRects(for:)` here; it can be stale
        // during the first layout pass (notably when SwiftUI/UITextView scroll state is settling),
        // which produces a vertically offset highlight until the user scrolls.
        layoutIfNeeded()
        if let tlm = textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        let rects = baseHighlightRects(in: range)

        guard rects.isEmpty == false else {
            textSelectionHighlightPath = nil
            rubySelectionHighlightPath = nil
            setNeedsDisplay()
            return
        }

        let basePath = UIBezierPath()
        let insets = selectionHighlightInsets

        // Prefer a "tight" glyph height (excludes lineSpacing/leading) so highlights
        // hug the text and don't include extra space below the line.
        let glyphHeight: CGFloat? = {
            guard let font else { return nil }
            let h = font.ascender - font.descender
            return h.isFinite && h > 0 ? h : nil
        }()

        for rect in rects {
            // `baseHighlightRects` returns glyph-enclosing rects in view coordinates.
            // When paragraph lineSpacing is used, these rects can include extra vertical
            // slack. Clamp to a tight glyph height anchored at the top of the rect.
            var highlightRect = rect
            if let glyphHeight {
                let h = min(glyphHeight, highlightRect.height)
                highlightRect.size.height = h
                highlightRect.origin.y = rect.minY
            }

            if insets != .zero {
                highlightRect.origin.x += insets.left
                highlightRect.origin.y += insets.top
                highlightRect.size.width -= (insets.left + insets.right)
                highlightRect.size.height -= (insets.top + insets.bottom)
            }
            guard highlightRect.width > 0, highlightRect.height > 0 else { continue }

            CustomLogger.shared.debug(String(format: "BASE highlight rect x=%.2f y=%.2f w=%.2f h=%.2f", highlightRect.origin.x, highlightRect.origin.y, highlightRect.size.width, highlightRect.size.height))
            basePath.append(UIBezierPath(roundedRect: highlightRect, cornerRadius: 4))
        }

        textSelectionHighlightPath = basePath.isEmpty ? nil : basePath
        rubySelectionHighlightPath = nil
        setNeedsDisplay()
    }

    private func baseHighlightRects(in characterRange: NSRange) -> [CGRect] {
        guard let attributedText else { return [] }
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return [] }
        guard NSMaxRange(characterRange) <= attributedText.length else { return [] }
        guard let uiRange = textRange(for: characterRange) else { return [] }

        // `selectionRects(for:)` returns usable per-line selection segments in view coordinates.
        // It can include vertical padding; clamp to TextKit 2 typographic bounds when possible.
        layoutIfNeeded()
        if let tlm = textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        let selectionRectsInView = selectionRects(for: uiRange)
            .map { $0.rect }
            .filter { $0.isNull == false && $0.isEmpty == false }

        guard selectionRectsInView.isEmpty == false else { return [] }

        let lineRectsInView = textKit2LineTypographicRectsInViewCoordinates(visibleOnly: true)
        guard lineRectsInView.isEmpty == false else { return selectionRectsInView }

        return selectionRectsInView.map { sel in
            guard let bestLine = bestMatchingLineRect(for: sel, candidates: lineRectsInView) else { return sel }
            var r = sel
            r.origin.y = bestLine.minY
            r.size.height = bestLine.height
            return r
        }
    }

    private func textKit2LineTypographicRectsInViewCoordinates(visibleOnly: Bool) -> [CGRect] {
        guard let tlm = textLayoutManager else { return [] }

        let inset = textContainerInset
        let offset = contentOffset

        let visibleRectInView: CGRect? = {
            guard visibleOnly else { return nil }
            // Expand a bit vertically so we still capture the correct line rect when ruby extends above.
            let extraY = max(16, rubyHighlightHeadroom + 12)
            return bounds.insetBy(dx: -4, dy: -extraY)
        }()

        var rects: [CGRect] = []
        tlm.ensureLayout(for: tlm.documentRange)
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            for line in fragment.textLineFragments {
                let r = line.typographicBounds
                let viewRect = CGRect(
                    x: r.origin.x + inset.left - offset.x,
                    y: r.origin.y + inset.top - offset.y,
                    width: r.size.width,
                    height: r.size.height
                )
                if viewRect.isNull == false, viewRect.isEmpty == false {
                    if let visibleRectInView {
                        if viewRect.intersects(visibleRectInView) == false { continue }
                    }
                    rects.append(viewRect)
                }
            }
            return false
        }
        return rects
    }

    private func bestMatchingLineRect(for rect: CGRect, candidates: [CGRect]) -> CGRect? {
        var best: CGRect? = nil
        var bestScore: CGFloat = 0

        for lineRect in candidates {
            let intersection = rect.intersection(lineRect)
            guard intersection.isNull == false, intersection.isEmpty == false else { continue }
            // Score by intersection area (stable when selection rect is slightly padded).
            let score = intersection.width * intersection.height
            if score > bestScore {
                bestScore = score
                best = lineRect
            }
        }

        return best
    }

    private func rubyHighlightRects(in selectionRange: NSRange) -> [CGRect] {
        guard let attributedText else { return [] }
        guard selectionRange.location != NSNotFound, selectionRange.length > 0 else { return [] }
        guard NSMaxRange(selectionRange) <= attributedText.length else { return [] }

        guard rubyAnnotationVisibility == .visible else { return [] }

        // Gather ruby-bearing subranges inside the selected span.
        var rubyRanges: [NSRange] = []
        attributedText.enumerateAttribute(.rubyReadingText, in: selectionRange, options: []) { value, range, _ in
            guard let s = value as? String, s.isEmpty == false else { return }
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
            if let tlm = textLayoutManager {
                let inset = textContainerInset
                let offset = contentOffset
                // Build an array of line rects in view coordinates
                var lineRects: [CGRect] = []

                // Ensure layout so fragments are available
                tlm.ensureLayout(for: tlm.documentRange)

                // Enumerate TextKit 2 layout fragments
                tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
                    for line in fragment.textLineFragments {
                        let r = line.typographicBounds
                        let viewRect = CGRect(
                            x: r.origin.x + inset.left - offset.x,
                            y: r.origin.y + inset.top - offset.y,
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
        guard rubyAnnotationVisibility == .visible else { return false }
        guard let attributedText else { return false }
        guard range.location != NSNotFound, range.length > 0 else { return false }
        guard NSMaxRange(range) <= attributedText.length else { return false }

        var hasRuby = false
        attributedText.enumerateAttribute(.rubyReadingText, in: range, options: []) { value, _, stop in
            if let s = value as? String, s.isEmpty == false {
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

    private func updateDragSelectionGestureState() {
        let alreadyAdded = gestureRecognizers?.contains(where: { $0 === dragSelectionRecognizer }) ?? false
        if isDragSelectionEnabled {
            if alreadyAdded == false {
                addGestureRecognizer(dragSelectionRecognizer)
            }
        } else {
            if alreadyAdded {
                removeGestureRecognizer(dragSelectionRecognizer)
            }
            dragSelectionAnchorUTF16 = nil
            dragSelectionActive = false
        }
    }

    @objc
    private func handleDragSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard isDragSelectionEnabled else { return }
        guard let backing = attributedText?.string as NSString? else { return }
        let length = backing.length
        guard length > 0 else { return }

        let point = recognizer.location(in: self)

        func composedRange(atUTF16Index index: Int) -> NSRange? {
            guard length > 0 else { return nil }
            let clamped = max(0, min(index, length - 1))
            return backing.rangeOfComposedCharacterSequence(at: clamped)
        }

        func utf16Index(at point: CGPoint) -> Int? {
            guard let pos = closestPosition(to: point) else { return nil }
            let offset = self.offset(from: beginningOfDocument, to: pos)
            return max(0, min(offset, length))
        }

        switch recognizer.state {
        case .began:
            dragSelectionBeganHandler?()
            dragSelectionActive = true
            guard let start = utf16Index(at: point) else {
                dragSelectionAnchorUTF16 = nil
                return
            }
            dragSelectionAnchorUTF16 = start
            if let r = composedRange(atUTF16Index: start) {
                applyInspectionHighlight(range: r)
            }

        case .changed:
            guard dragSelectionActive, let anchor = dragSelectionAnchorUTF16 else { return }
            guard let current = utf16Index(at: point) else { return }

            guard let anchorChar = composedRange(atUTF16Index: anchor) else { return }
            let currentChar: NSRange = {
                // If the current position is at EOF, treat it as selecting the last character.
                if current >= length {
                    return backing.rangeOfComposedCharacterSequence(at: length - 1)
                }
                return backing.rangeOfComposedCharacterSequence(at: max(0, current))
            }()

            let start = min(anchorChar.location, currentChar.location)
            let end = max(NSMaxRange(anchorChar), NSMaxRange(currentChar))
            let selected = NSRange(location: start, length: max(0, end - start))
            applyInspectionHighlight(range: selected.length > 0 ? selected : nil)

        case .ended, .cancelled, .failed:
            defer {
                dragSelectionAnchorUTF16 = nil
                dragSelectionActive = false
            }
            guard let selected = selectionHighlightRange, selected.length > 0 else { return }
            dragSelectionEndedHandler?(selected)

        default:
            break
        }
    }

    @objc
    private func handleInspectionTap(_ recognizer: UITapGestureRecognizer) {
        guard isTapInspectionEnabled, recognizer.state == .ended else { return }

        // INVESTIGATION NOTES (2026-01-04)
        // Token tap path runs synchronously on the main thread:
        // - glyph hit-testing / index resolution
        // - spanSelectionContext lookup
        // - highlight application + callback to SwiftUI
        // Also logs multiple debug lines per tap. If taps feel sluggish, check:
        // - spanSelectionContext(forUTF16Index:) complexity
        // - logging volume
        let tapPoint = recognizer.location(in: self)
        CustomLogger.shared.debug("Inspect tap at x=\(tapPoint.x) y=\(tapPoint.y)")

        guard let rawIndex = utf16IndexForTap(at: tapPoint) else {
            clearInspectionHighlight()
            CustomLogger.shared.debug("Inspect tap ignored: no glyph resolved")
            return
        }

        guard let resolvedIndex = resolvedTextIndex(from: rawIndex) else {
            clearInspectionHighlight()
            CustomLogger.shared.debug("Inspect tap unresolved: no base character near index=\(rawIndex)")
            return
        }

        if let characterTapHandler {
            // In character-tap mode, do not apply token highlights; just report the UTF-16 index.
            clearInspectionHighlight()
            characterTapHandler(resolvedIndex)
            return
        }

        guard let selection = spanSelectionContext(forUTF16Index: resolvedIndex) else {
            clearInspectionHighlight()
            CustomLogger.shared.debug("Inspect tap unresolved: no annotated span contains index=\(resolvedIndex)")
            return
        }

        applyInspectionHighlight(range: selection.highlightRange)
        notifySpanSelection(selection)

        if let details = inspectionDetails(forUTF16Index: resolvedIndex) {
            let charDescription = formattedCharacterDescription(details.character)
            let rangeDescription = "[\(details.utf16Range.location)..<\(NSMaxRange(details.utf16Range))]"
            let scalarsDescription = details.scalars.joined(separator: ", ")
            let indexSummary = rawIndex == resolvedIndex ? "\(resolvedIndex)" : "\(resolvedIndex) (resolved from \(rawIndex))"

            CustomLogger.shared.debug("Inspect tap char=\(charDescription) utf16Index=\(indexSummary) utf16Range=\(rangeDescription) scalars=[\(scalarsDescription)]")
        } else {
            let highlightDescription = "[\(selection.highlightRange.location)..<\(NSMaxRange(selection.highlightRange))]"
            CustomLogger.shared.debug("Inspect tap resolved to span range \(highlightDescription) but no character details could be extracted")
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
          // When drag-selection is enabled, long-press is reserved for selection.
          guard isDragSelectionEnabled == false else { return nil }
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
        guard let textRange = textRangeNearPoint(point),
              let closestPosition = textRange.start as UITextPosition? else { return nil }

        // `closestPosition(to:)` can snap to the previous line when tapping on an empty/blank line.
        // Gate the fallback hit-test so taps clearly below a line don't select its last glyph.
        let caret = caretRect(for: closestPosition)
        let upTolerance = max(6, rubyHighlightHeadroom + caret.height * 0.35)
        let downTolerance = max(6, caret.height * 0.35)
        if point.y < (caret.minY - upTolerance) || point.y > (caret.maxY + downTolerance) {
            return nil
        }

        let offset = offset(from: beginningOfDocument, to: closestPosition)
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
            let character = text[cursor]
            if character.isNewline { break }
            if isInspectableCharacter(character) { return cursor }
        }
        return nil
    }

    private func inspectableIndex(after index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            guard next < text.endIndex else { break }
            let character = text[next]
            if character.isNewline { break }
            if isInspectableCharacter(character) { return next }
            cursor = next
        }
        return nil
    }

    private func utf16Offset(of index: String.Index, in text: String) -> Int? {
        guard let utf16Position = index.samePosition(in: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Position)
    }

    private func isInspectableCharacter(_ character: Character) -> Bool {
        character.isNewline == false && character.isWhitespace == false
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
        guard let (tokenIndex, span) = semanticSpans.spanContext(containingUTF16Index: index) else { return nil }
        let spanRange = span.range
        guard spanRange.location != NSNotFound, spanRange.length > 0 else { return nil }
        return RubySpanSelection(tokenIndex: tokenIndex, semanticSpan: span, highlightRange: spanRange)
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
        guard let span = semanticSpans.spanContainingUTF16Index(index) else {
            CustomLogger.shared.debug("Inspect tap span unresolved: no semantic span contains index=\(index)")
            return
        }
        let spanRange = span.range
        let spanSurfaceDescription = span.surface.debugDescription
        let rangeDescription = "[\(spanRange.location)..<\(NSMaxRange(spanRange))]"
        CustomLogger.shared.debug("Inspect tap span surface=\(spanSurfaceDescription) range=\(rangeDescription)")
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
            CustomLogger.shared.error("Unable to install TextKit 1 guard for \(name)")
            return
        }
        method_exchangeImplementations(method, swizzledMethod)
    }

    private static func installGlyphRangeGuard() {
        guard let original = class_getInstanceMethod(NSLayoutManager.self, #selector(NSLayoutManager.glyphRange(for:))),
              let swizzled = class_getInstanceMethod(NSLayoutManager.self, #selector(NSLayoutManager.tk1_guardedGlyphRange(for:))) else {
            CustomLogger.shared.error("Unable to install TextKit 1 guard for glyphRange(for:)")
            return
        }
        method_exchangeImplementations(original, swizzled)
    }

    static func debugReportTextKit1Access(_ symbol: String) {
        let message = "⚠️ TextKit 1 API accessed: \(symbol). Use TextKit 2 layout primitives instead."
        CustomLogger.shared.warn(message)
        if ProcessInfo.processInfo.environment["KYOUKU_STRICT_TEXTKIT2"] == "1" {
            assertionFailure(message)
        }
    }

    @objc private func tk1_guarded_layoutManager() -> NSLayoutManager {
        Self.debugReportTextKit1Access("layoutManager")
        // After swizzling, the *original* implementation is reachable via this selector.
        let sel = #selector(TokenOverlayTextView.tk1_guarded_layoutManager)
        typealias Fn = @convention(c) (AnyObject, Selector) -> NSLayoutManager
        let imp = self.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(self, sel)
    }

    @objc private func tk1_guarded_textStorage() -> NSTextStorage {
        Self.debugReportTextKit1Access("textStorage")
        // After swizzling, the *original* implementation is reachable via this selector.
        let sel = #selector(TokenOverlayTextView.tk1_guarded_textStorage)
        typealias Fn = @convention(c) (AnyObject, Selector) -> NSTextStorage
        let imp = self.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(self, sel)
    }
#endif
}

#if DEBUG
extension NSLayoutManager {
    @objc fileprivate func tk1_guardedGlyphRange(for textContainer: NSTextContainer) -> NSRange {
        TokenOverlayTextView.debugReportTextKit1Access("glyphRange(for:)")
        // After swizzling, the *original* implementation is reachable via this selector.
        let sel = #selector(NSLayoutManager.tk1_guardedGlyphRange(for:))
        typealias Fn = @convention(c) (AnyObject, Selector, NSTextContainer) -> NSRange
        let imp = self.method(for: sel)
        let fn = unsafeBitCast(imp, to: Fn.self)
        return fn(self, sel, textContainer)
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

extension Collection where Element == SemanticSpan {
    func spanContainingUTF16Index(_ index: Int) -> SemanticSpan? {
        guard isEmpty == false, index >= 0 else { return nil }
        for span in self {
            let range = span.range
            guard range.location != NSNotFound else { continue }
            if NSLocationInRange(index, range) {
                return span
            }
        }
        return nil
    }

    func spanContext(containingUTF16Index index: Int) -> (Int, SemanticSpan)? {
        guard isEmpty == false, index >= 0 else { return nil }
        for (offset, span) in enumerated() {
            let range = span.range
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

