import SwiftUI
import UIKit
import CoreText

struct RubyText: UIViewRepresentable {
    struct ViewMetricsContext: Equatable {
        var pasteAreaFrame: CGRect?
        var tokenPanelFrame: CGRect?

        init(pasteAreaFrame: CGRect? = nil, tokenPanelFrame: CGRect? = nil) {
            self.pasteAreaFrame = pasteAreaFrame
            self.tokenPanelFrame = tokenPanelFrame
        }
    }

    var attributed: NSAttributedString
    /// Preferred base font PostScript name.
    /// If nil/empty/unavailable, falls back to system.
    var fontName: String? = nil
    var fontSize: CGFloat
    var lineHeightMultiple: CGFloat
    var extraGap: CGFloat
    /// Absolute gap between ruby and headword (in points). 0 means “touching”.
    var rubyBaselineGap: CGFloat = 0.5
    var textInsets: UIEdgeInsets = RubyText.defaultInsets
    var bottomOverlayHeight: CGFloat = 0
    var annotationVisibility: RubyAnnotationVisibility = .visible
    var isScrollEnabled: Bool = false
    var allowSystemTextSelection: Bool = true
    var globalKerning: CGFloat = 0
    var padHeadwordSpacing: Bool = false
    var rubyHorizontalAlignment: RubyHorizontalAlignment = .center
    var wrapLines: Bool = true
    var horizontalScrollEnabled: Bool = false
    var scrollSyncGroupID: String? = nil
    var tokenOverlays: [TokenOverlay] = []
    var tokenColorPalette: [UIColor] = []
    var semanticSpans: [SemanticSpan] = []
    /// Extra horizontal spacing (in points) inserted at SOURCE UTF-16 boundary indices.
    /// Implemented via display-only width attachments so ruby/headword stay aligned.
    var interTokenSpacing: [Int: CGFloat] = [:]
    var selectedRange: NSRange? = nil
    /// Increment this token to request a one-shot scroll-to-selected-range.
    ///
    /// This is intentionally separate from `selectedRange` updates to avoid selection-induced
    /// scroll jumps during normal view refreshes.
    var scrollToSelectedRangeToken: Int = 0
    var customizedRanges: [NSRange] = []
    var alternateTokenColorsEnabled: Bool = false
    var enableTapInspection: Bool = true
    var enableDragSelection: Bool = false
    /// When enabled, applies a distinct font to kanji runs (kana/other stay base font).
    var distinctKanaKanjiFonts: Bool = false
    var onDragSelectionBegan: (() -> Void)? = nil
    var onDragSelectionEnded: ((NSRange) -> Void)? = nil
    var onCharacterTap: ((Int) -> Void)? = nil
    var onSpanSelection: ((RubySpanSelection?) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var onContextMenuAction: ((RubyContextMenuAction) -> Void)? = nil
    /// Optional drag-to-adjust token spacing support.
    /// These callbacks are invoked from the underlying TokenOverlayTextView.
    var tokenSpacingValueProvider: ((Int) -> CGFloat)? = nil
    var onTokenSpacingChanged: ((Int, CGFloat, Bool) -> Void)? = nil
    var viewMetricsContext: ViewMetricsContext? = nil
    /// Debug hook: emits a token listing string with layout-derived line numbers and coordinates.
    /// Intended for PasteView's token-index popover.
    var onDebugTokenListTextChange: ((String) -> Void)? = nil

    static let defaultInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    private static let verboseRubyLoggingEnabled: Bool = {
        ProcessInfo.processInfo.environment["RUBY_TRACE"] == "1"
    }()

    struct TokenOverlay: Equatable {
        let range: NSRange
        let color: UIColor

        static func == (lhs: TokenOverlay, rhs: TokenOverlay) -> Bool {
            lhs.range == rhs.range && lhs.color.isEqual(rhs.color)
        }
    }

    private func resolvedBaseFont(ofSize size: CGFloat) -> UIFont {
        if let fontName, fontName.isEmpty == false, let font = UIFont(name: fontName, size: size) {
            return font
        }
        return UIFont.systemFont(ofSize: size)
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
        textView.textContainer.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
        if wrapLines == false {
            // Avoid an initial wrapped layout before SwiftUI's first `sizeThatFits` pass.
            textView.textContainer.size = CGSize(width: RubyTextConstants.noWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.textContainerInset = textInsets
        textView.clipsToBounds = true
        textView.layer.masksToBounds = true
        textView.tintColor = .systemBlue
        textView.font = resolvedBaseFont(ofSize: fontSize)
        textView.padHeadwordSpacing = padHeadwordSpacing
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.isTapInspectionEnabled = enableTapInspection
        textView.isDragSelectionEnabled = enableDragSelection
        textView.dragSelectionBeganHandler = onDragSelectionBegan
        textView.dragSelectionEndedHandler = onDragSelectionEnded
        textView.spanSelectionHandler = onSpanSelection
        textView.debugTokenListTextHandler = onDebugTokenListTextChange
        textView.characterTapHandler = onCharacterTap
        textView.contextMenuStateProvider = contextMenuStateProvider
        textView.contextMenuActionHandler = onContextMenuAction
        textView.tokenSpacingValueProvider = tokenSpacingValueProvider
        textView.tokenSpacingChangedHandler = onTokenSpacingChanged
        textView.viewMetricsContext = viewMetricsContext
        textView.tokenColorPalette = tokenColorPalette
        textView.alternateTokenColorsEnabled = alternateTokenColorsEnabled
        textView.delegate = context.coordinator

        context.coordinator.attach(textView: textView, scrollSyncGroupID: scrollSyncGroupID)

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
        let priorWrapLines = uiView.wrapLines
        let priorHorizontalScrollEnabled = uiView.horizontalScrollEnabled
        let priorTextContainerInset = uiView.textContainerInset
        let wasSelectable = uiView.isSelectable

        let baseFont = resolvedBaseFont(ofSize: fontSize)
        uiView.font = baseFont
        uiView.tintColor = .systemBlue

        // Keep a stable SOURCE string for debug token reporting. `uiView.attributedText` may
        // be modified (e.g. ruby-width padding inserts U+FFFC), so semantic span ranges would
        // no longer index into it correctly.
        uiView.debugSourceText = attributed.string as NSString

        uiView.rubyAnnotationVisibility = annotationVisibility
        uiView.isEditable = false
        uiView.isSelectable = allowSystemTextSelection
        uiView.isScrollEnabled = isScrollEnabled
        uiView.wrapLines = wrapLines
        uiView.horizontalScrollEnabled = horizontalScrollEnabled
        uiView.textContainer.widthTracksTextView = false
        uiView.textContainer.maximumNumberOfLines = 0
        uiView.textContainer.lineBreakMode = wrapLines ? .byCharWrapping : .byClipping
        if wrapLines == false, uiView.textContainer.size.width < RubyTextConstants.noWrapContainerWidth {
            uiView.textContainer.size = CGSize(width: RubyTextConstants.noWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
        }

        if allowSystemTextSelection == false {
            // Avoid touching `selectedRange` on every update.
            // Setting `selectedRange` can snap the scroll position to the top, which
            // looks like a "jump" when other unrelated state changes trigger an update.
            if wasSelectable {
                uiView.selectedRange = NSRange(location: 0, length: 0)
                uiView.resignFirstResponder()
            }
            if #available(iOS 11.0, *) {
                uiView.textDragInteraction?.isEnabled = false
            }
        } else {
            if #available(iOS 11.0, *) {
                uiView.textDragInteraction?.isEnabled = true
            }
        }

        // Gap between ruby and headword.
        // This is an absolute value; 0 means the ruby bottom sits flush on the headword top.
        let resolvedRubyBaselineGap = max(0, rubyBaselineGap)

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
                    baseFont: baseFont,
                    defaultRubyFontSize: defaultRubyFontSize,
                    rubyBaselineGap: resolvedRubyBaselineGap
                )
            )
        )

        let rubyMetricsEnabled = (annotationVisibility != .removed)

        // Reserve ruby headroom via container inset at the top of the document.
        // We intentionally avoid fragment `topMargin` for spacing because TextKit 2 only
        // applies it to the first line of each fragment, which creates inconsistent gaps.
        var insets = textInsets
        if rubyMetricsEnabled {
            insets.top += max(0, rubyHeadroom)

            // Prevent ruby overhang/clipping at the container edges.
            // When headword padding is enabled, we may center a wide ruby reading over its
            // base run by inserting invisible width on both sides; at line starts/ends this
            // needs real horizontal slack so ruby never extends into the inset boundary.
            // Compute a conservative inset based on the largest ruby font size present.
            let rubyHorizontalInset = RubyText.requiredHorizontalInsetForRubyOverhang(
                in: attributed,
                baseFont: baseFont,
                defaultRubyFontSize: defaultRubyFontSize
            )
            if rubyHorizontalInset > 0 {
                insets.left += rubyHorizontalInset
                insets.right += rubyHorizontalInset
            }
        }

        uiView.rubyHighlightHeadroom = rubyHeadroom
        uiView.rubyBaselineGap = resolvedRubyBaselineGap
        uiView.rubyReservedTopMargin = 0

        // IMPORTANT:
        // TextKit 2 `NSTextLayoutFragment.topMargin` only reserves space above the *first* line
        // of each fragment, not above every visual line. Paragraph-level spacing is the most
        // reliable way to ensure *every* wrapped line has enough vertical room for ruby.
        //
        // Use a minimum line height that includes the ruby headroom.
        // Allocate vertical room for ruby on EVERY visual line (including soft wraps).
        // TextKit 2 fragment `topMargin` cannot cover subsequent wrapped lines.
        let effectiveLineSpacing: CGFloat = {
            let base = max(0, extraGap)
            guard rubyMetricsEnabled else { return base }
            // Reserve at least the ruby headroom between baselines so ruby from the next line
            // cannot collide with the base glyphs of the previous line.
            return max(base, rubyHeadroom)
        }()

        // Keep selection highlight geometry stable even when we don't reapply attributed text.
        uiView.selectionHighlightInsets = selectionHighlightInsets(for: baseFont)

        var renderHasher = Hasher()
        renderHasher.combine(ObjectIdentifier(attributed))
        renderHasher.combine(attributed.length)
        renderHasher.combine(Int((fontSize * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((lineHeightMultiple * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((extraGap * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((globalKerning * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((max(0, rubyBaselineGap) * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(Int((rubyHeadroom * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(rubyMetricsEnabled ? 1 : 0)
        renderHasher.combine(Int((effectiveLineSpacing * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(rubyHorizontalAlignment == .leading ? 1 : 0)
        renderHasher.combine(padHeadwordSpacing ? 1 : 0)
        renderHasher.combine(wrapLines ? 1 : 0)
        // Ruby visibility affects layout, because we may reserve different vertical headroom
        // (paragraph spacing + top inset) depending on whether ruby should be shown.
        // Treat all visibility transitions as layout-affecting so toggling furigana cannot
        // leave stale paragraph metrics and cause overlaps.
        let annotationVisibilityFlag: Int = {
            switch annotationVisibility {
            case .visible:
                return 0
            case .hiddenKeepMetrics:
                return 1
            case .removed:
                return 2
            }
        }()
        renderHasher.combine(annotationVisibilityFlag)
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
        renderHasher.combine(interTokenSpacing.count)
        for key in interTokenSpacing.keys.sorted() {
            renderHasher.combine(key)
            let w = interTokenSpacing[key] ?? 0
            renderHasher.combine(Int((w * 1000).rounded(.toNearestOrEven)))
        }
        let renderKey = renderHasher.finalize()
        let shouldReapplyAttributedText = (uiView.lastAppliedRenderKey != renderKey) || (uiView.attributedText == nil)

        // Ensure insets are applied before attributedText updates so TextKit computes
        // content size / clamping using the correct bottom padding.
        if shouldReapplyAttributedText, priorTextContainerInset != insets {
            let savedOffset = uiView.contentOffset
            uiView.textContainerInset = insets
            uiView.layoutIfNeeded()
            let inset = uiView.adjustedContentInset
            let minY = -inset.top
            let maxY = max(minY, uiView.contentSize.height - uiView.bounds.height + inset.bottom)
            let clampedY = min(max(savedOffset.y, minY), maxY)
            let minX = -inset.left
            let maxX = max(minX, uiView.contentSize.width - uiView.bounds.width + inset.right)
            let clampedX = min(max(savedOffset.x, minX), maxX)
            let clamped = CGPoint(x: clampedX, y: clampedY)
            if (clamped.y - uiView.contentOffset.y).magnitude > 0.5 || (clamped.x - uiView.contentOffset.x).magnitude > 0.5 {
                uiView.setContentOffset(clamped, animated: false)
            }
        }

        if shouldReapplyAttributedText {

            let mutable = NSMutableAttributedString(attributedString: attributed)
            let fullRange = NSRange(location: 0, length: mutable.length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
            if #available(iOS 14.0, *) {
                // Avoid `.pushOut`: it can push trailing punctuation onto the next line,
                // creating leading commas/periods. TokenOverlayTextView already gates soft
                // breaks using semantic token boundaries.
                paragraph.lineBreakStrategy = []
            }
            paragraph.lineHeightMultiple = max(0.8, lineHeightMultiple)
            paragraph.lineSpacing = effectiveLineSpacing
            paragraph.minimumLineHeight = 0
            paragraph.maximumLineHeight = 0
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
            mutable.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)
            mutable.addAttribute(.font, value: baseFont, range: fullRange)

            if distinctKanaKanjiFonts {
                let kanjiFont = ScriptFontStyler.resolveKanjiFont(baseFont: baseFont)
                ScriptFontStyler.applyDistinctKanaKanjiFonts(to: mutable, kanjiFont: kanjiFont)
            }

            if abs(globalKerning) > 0.001 {
                // Apply global kerning to every character without clobbering any existing
                // per-run kerning (e.g. headword padding adjustments).
                var existing: [(NSRange, CGFloat)] = []
                existing.reserveCapacity(64)
                mutable.enumerateAttribute(.kern, in: fullRange, options: []) { value, range, _ in
                    let kern: CGFloat? = {
                        if let num = value as? NSNumber { return CGFloat(num.doubleValue) }
                        if let cg = value as? CGFloat { return cg }
                        if let dbl = value as? Double { return CGFloat(dbl) }
                        return nil
                    }()
                    if let kern, kern.isFinite {
                        existing.append((range, kern))
                    }
                }

                mutable.addAttribute(.kern, value: globalKerning, range: fullRange)
                for (range, kern) in existing {
                    mutable.addAttribute(.kern, value: kern + globalKerning, range: range)
                }
            }

            if tokenOverlays.isEmpty == false {
                RubyTextProcessing.applyTokenColors(tokenOverlays, to: mutable)
            }

            if customizedRanges.isEmpty == false {
                RubyTextProcessing.applyCustomizationHighlights(customizedRanges, to: mutable)
            }

            let processed = RubyTextProcessing.applyAnnotationVisibility(annotationVisibility, to: mutable)

            let (displayText, indexMap) = RubyTextProcessing.applyRubyWidthPaddingAroundRunsIfNeeded(
                to: processed,
                baseFont: baseFont,
                defaultRubyFontSize: defaultRubyFontSize,
                enabled: padHeadwordSpacing && annotationVisibility != .removed,
                interTokenSpacing: interTokenSpacing
            )
            uiView.rubyIndexMap = indexMap
            uiView.applyAttributedText(displayText)
            uiView.lastAppliedRenderKey = renderKey
        }

        // Insets can change when bottom overlays (e.g. token action panel) appear/disappear.
        // Preserve scroll position across inset updates to avoid selection-induced "jumps".
        if priorTextContainerInset != insets, shouldReapplyAttributedText == false {
            let savedOffset = uiView.contentOffset
            let isInteracting = uiView.isTracking || uiView.isDragging || uiView.isDecelerating
            uiView.textContainerInset = insets
            uiView.layoutIfNeeded()
            if isInteracting == false {
                let inset = uiView.adjustedContentInset
                let minY = -inset.top
                let maxY = max(minY, uiView.contentSize.height - uiView.bounds.height + inset.bottom)
                let clampedY = min(max(savedOffset.y, minY), maxY)
                let minX = -inset.left
                let maxX = max(minX, uiView.contentSize.width - uiView.bounds.width + inset.right)
                let clampedX = min(max(savedOffset.x, minX), maxX)
                let clamped = CGPoint(x: clampedX, y: clampedY)
                if (clamped.y - uiView.contentOffset.y).magnitude > 0.5 || (clamped.x - uiView.contentOffset.x).magnitude > 0.5 {
                    uiView.setContentOffset(clamped, animated: false)
                }
            }
        }
        uiView.semanticSpans = semanticSpans
        let displaySelectedRange = selectedRange.map { uiView.displayRange(fromSourceRange: $0) }
        uiView.selectionHighlightRange = displaySelectedRange
        uiView.isTapInspectionEnabled = enableTapInspection
        uiView.isDragSelectionEnabled = enableDragSelection
        uiView.padHeadwordSpacing = padHeadwordSpacing
        uiView.rubyHorizontalAlignment = rubyHorizontalAlignment
        uiView.dragSelectionBeganHandler = onDragSelectionBegan
        uiView.dragSelectionEndedHandler = onDragSelectionEnded
        uiView.spanSelectionHandler = onSpanSelection
        uiView.debugTokenListTextHandler = onDebugTokenListTextChange
        uiView.characterTapHandler = onCharacterTap
        uiView.contextMenuStateProvider = contextMenuStateProvider
        uiView.contextMenuActionHandler = onContextMenuAction
        uiView.tokenSpacingValueProvider = tokenSpacingValueProvider
        uiView.tokenSpacingChangedHandler = onTokenSpacingChanged
        uiView.viewMetricsContext = viewMetricsContext
        uiView.tokenColorPalette = tokenColorPalette
        uiView.alternateTokenColorsEnabled = alternateTokenColorsEnabled

        context.coordinator.stateProvider = contextMenuStateProvider
        context.coordinator.actionHandler = onContextMenuAction

        context.coordinator.attach(textView: uiView, scrollSyncGroupID: scrollSyncGroupID)

        // Only resync when layout-affecting config changes; do not resync on highlight-only updates.
        let wrapModeChanged = (priorWrapLines != wrapLines) || (priorHorizontalScrollEnabled != horizontalScrollEnabled)
        if shouldReapplyAttributedText || wrapModeChanged {
            context.coordinator.resyncToLatestSnapshotIfIdle()
        }

        // If a bottom overlay covers the selected token, scroll just enough to reveal it.
        let overlay = max(0, bottomOverlayHeight)
        let selectionChanged = (context.coordinator.lastAutoEnsureSelectionRange != selectedRange)
        let overlayChanged = abs(context.coordinator.lastAutoEnsureOverlayHeight - overlay) > 0.5
        if overlay > 0, let displaySelectedRange, displaySelectedRange.length > 0, (selectionChanged || overlayChanged) {
            uiView.ensureHighlightedRangeVisibleIfCovered(displaySelectedRange, bottomOverlayHeight: overlay)
        }
        context.coordinator.lastAutoEnsureSelectionRange = selectedRange
        context.coordinator.lastAutoEnsureOverlayHeight = overlay

        // One-shot explicit scroll request (e.g., constellation tap).
        let scrollTokenChanged = (context.coordinator.lastScrollToSelectedRangeToken != scrollToSelectedRangeToken)
        if scrollTokenChanged, let displaySelectedRange, displaySelectedRange.length > 0 {
            uiView.ensureHighlightedRangeVisible(displaySelectedRange, bottomOverlayHeight: overlay)
        }
        context.coordinator.lastScrollToSelectedRangeToken = scrollToSelectedRangeToken

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
            // On first load, SwiftUI may ask for a size before a concrete proposal width exists.
            // Prefer the actual window width (when available) so we measure with the same
            // constraint we’ll render with, avoiding a “different wrap” until rotation.
            if let w = uiView.window?.bounds.width, w.isFinite, w > 0 {
                return w
            }
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
            targetWidth = max(targetWidth, RubyTextConstants.noWrapContainerWidth)
        }

        uiView.lastMeasuredBoundsWidth = snappedBaseWidth
        uiView.lastMeasuredTextContainerWidth = targetWidth
        if abs(uiView.textContainer.size.width - targetWidth) > 0.5 {
            uiView.textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)

            // TextKit 2 can be viewport-lazy; when the container width changes during measurement,
            // force layout invalidation so wrapping/anchor geometry settles immediately.
            if #available(iOS 15.0, *) {
                if let tlm = uiView.textLayoutManager {
                    tlm.invalidateLayout(for: tlm.documentRange)
                }
            }
            uiView.setNeedsLayout()
        }

        let shouldLog = (proposedWidth == nil) || abs(uiView.bounds.width - snappedBaseWidth) > 0.5
        if Self.verboseRubyLoggingEnabled && shouldLog {
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

        var lastAutoEnsureSelectionRange: NSRange? = nil
        var lastAutoEnsureOverlayHeight: CGFloat = 0
        var lastScrollToSelectedRangeToken: Int = 0

        private weak var textView: UITextView?
        private var scrollSyncGroupID: String? = nil
        private let scrollSyncSourceID: String = UUID().uuidString
        private var scrollObserver: NSObjectProtocol? = nil
        private var isApplyingExternalScroll: Bool = false

        deinit {
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        func attach(textView: UITextView, scrollSyncGroupID: String?) {
            self.textView = textView
            if self.scrollSyncGroupID != scrollSyncGroupID {
                self.scrollSyncGroupID = scrollSyncGroupID
            }

            if scrollObserver == nil {
                scrollObserver = NotificationCenter.default.addObserver(
                    forName: .kyoukuSplitPaneScrollSync,
                    object: nil,
                    queue: .main
                ) { [weak self] note in
                    self?.handleScrollSyncNotification(note)
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isApplyingExternalScroll == false else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard let tv = textView, tv === scrollView else { return }

            // Only broadcast user-driven motion. Programmatic offset updates (from sync)
            // can trigger additional delegate callbacks; broadcasting those creates
            // a feedback loop that manifests as elastic snap-back.
            guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }

            // Sync by (fraction within scrollable range) + (overscroll delta) so both panes
            // stay aligned even when their content sizes differ.
            //
            // IMPORTANT: When wrapping is enabled, horizontal scroll isn't meaningful.
            // Do not broadcast X motion in that mode (otherwise the other pane can get
            // dragged around by tiny inset-related ranges).
            let inset = scrollView.adjustedContentInset
            let allowHorizontal: Bool = {
                guard let tv = scrollView as? TokenOverlayTextView else { return false }
                return tv.horizontalScrollEnabled && (tv.wrapLines == false)
            }()

            let normalizedX = allowHorizontal ? (scrollView.contentOffset.x + inset.left) : 0
            let normalizedY = scrollView.contentOffset.y + inset.top
            let maxX = allowHorizontal ? max(0, scrollView.contentSize.width - scrollView.bounds.width + inset.left + inset.right) : 0
            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height + inset.top + inset.bottom)

            let inRangeX = min(max(normalizedX, 0), maxX)
            let inRangeY = min(max(normalizedY, 0), maxY)
            let fracX: CGFloat = (maxX > 0) ? (inRangeX / maxX) : 0
            let fracY: CGFloat = (maxY > 0) ? (inRangeY / maxY) : 0

            let overscrollX: CGFloat = {
                guard allowHorizontal else { return 0 }
                if normalizedX < 0 { return normalizedX }
                if normalizedX > maxX { return normalizedX - maxX }
                return 0
            }()
            let overscrollY: CGFloat = {
                if normalizedY < 0 { return normalizedY }
                if normalizedY > maxY { return normalizedY - maxY }
                return 0
            }()

            SplitPaneScrollSyncStore.record(
                group: group,
                snapshot: SplitPaneScrollSyncStore.Snapshot(
                    source: scrollSyncSourceID,
                    fx: fracX,
                    fy: fracY,
                    ox: overscrollX,
                    oy: overscrollY,
                    sx: maxX,
                    sy: maxY,
                    timestamp: CFAbsoluteTimeGetCurrent()
                )
            )

            NotificationCenter.default.post(
                name: .kyoukuSplitPaneScrollSync,
                object: nil,
                userInfo: [
                    "group": group,
                    "source": scrollSyncSourceID,
                    "fx": fracX,
                    "fy": fracY,
                    "ox": overscrollX,
                    "oy": overscrollY,
                    "sx": maxX,
                    "sy": maxY
                ]
            )
        }

        func resyncToLatestSnapshotIfIdle() {
            guard isApplyingExternalScroll == false else { return }
            guard let tv = textView else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard tv.isTracking == false, tv.isDragging == false, tv.isDecelerating == false else { return }
            guard let snap = SplitPaneScrollSyncStore.latest(group: group) else { return }
            guard snap.source != scrollSyncSourceID else { return }

            let info: [String: Any] = [
                "group": group,
                "source": snap.source,
                "fx": snap.fx,
                "fy": snap.fy,
                "ox": snap.ox,
                "oy": snap.oy,
                "sx": snap.sx,
                "sy": snap.sy
            ]
            handleScrollSyncNotification(Notification(name: .kyoukuSplitPaneScrollSync, object: nil, userInfo: info))
        }

        private func handleScrollSyncNotification(_ note: Notification) {
            guard let tv = textView else { return }
            guard let group = scrollSyncGroupID, group.isEmpty == false else { return }
            guard let info = note.userInfo else { return }
            guard let noteGroup = info["group"] as? String, noteGroup == group else { return }
            guard let source = info["source"] as? String, source != scrollSyncSourceID else { return }

            let fx = (info["fx"] as? CGFloat) ?? CGFloat((info["fx"] as? Double) ?? 0)
            let fy = (info["fy"] as? CGFloat) ?? CGFloat((info["fy"] as? Double) ?? 0)
            let ox = (info["ox"] as? CGFloat) ?? CGFloat((info["ox"] as? Double) ?? 0)
            let oy = (info["oy"] as? CGFloat) ?? CGFloat((info["oy"] as? Double) ?? 0)
            let sx = (info["sx"] as? CGFloat) ?? CGFloat((info["sx"] as? Double) ?? 0)
            let sy = (info["sy"] as? CGFloat) ?? CGFloat((info["sy"] as? Double) ?? 0)

            tv.layoutIfNeeded()

            let inset = tv.adjustedContentInset
            let maxX = max(0, tv.contentSize.width - tv.bounds.width + inset.left + inset.right)
            let maxY = max(0, tv.contentSize.height - tv.bounds.height + inset.top + inset.bottom)

            let clampedFX: CGFloat = min(max(fx, 0), 1)
            let clampedFY: CGFloat = min(max(fy, 0), 1)

            // If the source view isn't horizontally scrollable (sx == 0), do not force our X
            // position. This matters when one pane wraps and the other does not: the wrapped
            // pane would otherwise keep snapping the no-wrap pane back to x≈0.
            let currentNormalizedX = tv.contentOffset.x + inset.left
            let currentNormalizedY = tv.contentOffset.y + inset.top

            let shouldSyncX = (sx > 0) && (maxX > 0)
            let shouldSyncY = (sy > 0) && (maxY > 0)

            let effectiveFX: CGFloat = shouldSyncX ? clampedFX : 0
            let effectiveFY: CGFloat = shouldSyncY ? clampedFY : 0

            let desiredNormalized = CGPoint(
                x: shouldSyncX ? ((maxX * effectiveFX) + ox) : currentNormalizedX,
                y: shouldSyncY ? ((maxY * effectiveFY) + oy) : currentNormalizedY
            )

            let desired = CGPoint(
                x: desiredNormalized.x - inset.left,
                y: desiredNormalized.y - inset.top
            )

            // Clamp to an extended range so "bounce" overscroll stays synchronized.
            let minX = -inset.left
            let maxOffsetX = max(minX, tv.contentSize.width - tv.bounds.width + inset.right)
            let minY = -inset.top
            let maxOffsetY = max(minY, tv.contentSize.height - tv.bounds.height + inset.bottom)
            let allowX = max(60, tv.bounds.width * 0.25)
            let allowY = max(60, tv.bounds.height * 0.25)
            let clamped = CGPoint(
                x: min(max(desired.x, minX - allowX), maxOffsetX + allowX),
                y: min(max(desired.y, minY - allowY), maxOffsetY + allowY)
            )

            isApplyingExternalScroll = true
            if abs(tv.contentOffset.x - clamped.x) > 0.5 || abs(tv.contentOffset.y - clamped.y) > 0.5 {
                tv.setContentOffset(clamped, animated: false)
            }
            DispatchQueue.main.async { [weak self] in
                self?.isApplyingExternalScroll = false
            }
        }

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
        // Nudge the highlight in from the glyph bounds so it falls cleanly on
        // the visible headword without bleeding into adjacent spacing.
        let pointSize = max(1, font.pointSize)
        let horizontalInset = max(0.5, pointSize * 0.08)
        let verticalInset = max(0.5, pointSize * 0.06)

        // Preserve a tiny bit of extra space below the glyphs so highlights
        // don't feel cramped when additional line spacing is configured.
        let spacing = max(0, extraGap)
        let bottomInset = max(verticalInset, spacing * 0.15)

        return UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: bottomInset, right: horizontalInset)
    }

    static func requiredVerticalHeadroomForRuby(
        in attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat,
        rubyBaselineGap: CGFloat
    ) -> CGFloat {
        RubyTextProcessing.requiredVerticalHeadroomForRuby(
            in: attributed,
            baseFont: baseFont,
            defaultRubyFontSize: defaultRubyFontSize,
            rubyBaselineGap: rubyBaselineGap
        )
    }

    static func requiredHorizontalInsetForRubyOverhang(
        in attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat
    ) -> CGFloat {
        RubyTextProcessing.requiredHorizontalInsetForRubyOverhang(
            in: attributed,
            baseFont: baseFont,
            defaultRubyFontSize: defaultRubyFontSize
        )
    }

    static func measureTypographicSize(_ attributed: NSAttributedString) -> CGSize {
        RubyTextProcessing.measureTypographicSize(attributed)
    }

}
