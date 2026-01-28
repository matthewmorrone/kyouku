import SwiftUI
import UIKit
import CoreText

private let RubyDebugBoundingDefaultStrokeColor = UIColor.systemPink.withAlphaComponent(0.9)
private let RubyDebugBoundingDarkModeStrokeColor = UIColor(white: 1.0, alpha: 0.92)
private let RubyDebugBoundingDashPattern: [NSNumber] = [4, 3]

// When wrapping is disabled, we rely on a very wide text container so TextKit lays out
// long lines without wrapping and UIScrollView has a meaningful horizontal contentSize.
// Keep this large enough to accommodate real-world pasted text.
private let RubyNoWrapContainerWidth: CGFloat = 200_000

extension Notification.Name {
    static let kyoukuSplitPaneScrollSync = Notification.Name("kyouku.splitPane.scrollSync")
}

@MainActor
enum SplitPaneScrollSyncStore {
    struct Snapshot {
        let source: String
        let fx: CGFloat
        let fy: CGFloat
        let ox: CGFloat
        let oy: CGFloat
        let sx: CGFloat
        let sy: CGFloat
        let timestamp: CFTimeInterval
    }

    private static var latestByGroup: [String: Snapshot] = [:]

    static func record(group: String, snapshot: Snapshot) {
        latestByGroup[group] = snapshot
    }

    static func latest(group: String) -> Snapshot? {
        latestByGroup[group]
    }
}

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

enum RubyHorizontalAlignment {
    case center
    case leading
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
    var onDragSelectionBegan: (() -> Void)? = nil
    var onDragSelectionEnded: ((NSRange) -> Void)? = nil
    var onCharacterTap: ((Int) -> Void)? = nil
    var onSpanSelection: ((RubySpanSelection?) -> Void)? = nil
    var contextMenuStateProvider: (() -> RubyContextMenuState?)? = nil
    var onContextMenuAction: ((RubyContextMenuAction) -> Void)? = nil
    var viewMetricsContext: ViewMetricsContext? = nil

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
        textView.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        if wrapLines == false {
            // Avoid an initial wrapped layout before SwiftUI's first `sizeThatFits` pass.
            textView.textContainer.size = CGSize(width: RubyNoWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
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
        textView.characterTapHandler = onCharacterTap
        textView.contextMenuStateProvider = contextMenuStateProvider
        textView.contextMenuActionHandler = onContextMenuAction
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
        uiView.rubyAnnotationVisibility = annotationVisibility
        uiView.isEditable = false
        uiView.isSelectable = allowSystemTextSelection
        uiView.isScrollEnabled = isScrollEnabled
        uiView.wrapLines = wrapLines
        uiView.horizontalScrollEnabled = horizontalScrollEnabled
        uiView.textContainer.widthTracksTextView = false
        uiView.textContainer.maximumNumberOfLines = 0
        uiView.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        if wrapLines == false, uiView.textContainer.size.width < RubyNoWrapContainerWidth {
            uiView.textContainer.size = CGSize(width: RubyNoWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
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
                    baseFont: baseFont,
                    defaultRubyFontSize: defaultRubyFontSize,
                    rubyBaselineGap: rubyBaselineGap
                )
            )
        )

        let insets = textInsets
        // Ruby headroom is reserved via custom TextKit 2 layout fragments (topMargin).
        // Keep container inset stable so we don't introduce global top padding.
        uiView.rubyHighlightHeadroom = rubyHeadroom
        uiView.rubyBaselineGap = rubyBaselineGap
        uiView.rubyReservedTopMargin = (annotationVisibility == .removed) ? 0 : max(0, rubyHeadroom)

        // IMPORTANT:
        // TextKit 2 `NSTextLayoutFragment.topMargin` only reserves space above the *first* line
        // of each fragment, not above every visual line. Paragraph-level spacing is the most
        // reliable way to ensure *every* wrapped line has enough vertical room for ruby.
        //
        // Use a minimum line height that includes the ruby headroom.
        let rubyMetricsEnabled = (annotationVisibility != .removed)

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
        renderHasher.combine(Int((rubyHeadroom * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(rubyMetricsEnabled ? 1 : 0)
        renderHasher.combine(Int((effectiveLineSpacing * 1000).rounded(.toNearestOrEven)))
        renderHasher.combine(rubyHorizontalAlignment == .leading ? 1 : 0)
        renderHasher.combine(wrapLines ? 1 : 0)
        // Only treat `.removed` as a layout-affecting change; `.visible` vs
        // `.hiddenKeepMetrics` share identical metrics, so toggling furigana
        // visibility does not force a reapplication or resync.
        let removeAnnotationsFlag = (annotationVisibility == .removed) ? 1 : 0
        renderHasher.combine(removeAnnotationsFlag)
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
                // Prefer pushing a word/token to the next line instead of breaking inside it.
                // This is especially important for Japanese text where system “word” boundaries
                // can effectively be per-character.
                paragraph.lineBreakStrategy = wrapLines ? [.pushOut] : []
            }
            paragraph.lineHeightMultiple = max(0.8, lineHeightMultiple)
            paragraph.lineSpacing = effectiveLineSpacing
            paragraph.minimumLineHeight = 0
            paragraph.maximumLineHeight = 0
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
            mutable.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)
            mutable.addAttribute(.font, value: baseFont, range: fullRange)

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
                RubyText.applyTokenColors(tokenOverlays, to: mutable)
            }

            if customizedRanges.isEmpty == false {
                RubyText.applyCustomizationHighlights(customizedRanges, to: mutable)
            }

            let processed = RubyText.applyAnnotationVisibility(annotationVisibility, to: mutable)

            let (displayText, indexMap) = RubyText.applyRubyWidthPaddingAroundRunsIfNeeded(
                to: processed,
                baseFont: baseFont,
                defaultRubyFontSize: defaultRubyFontSize,
                enabled: padHeadwordSpacing && annotationVisibility != .removed
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
        uiView.characterTapHandler = onCharacterTap
        uiView.contextMenuStateProvider = contextMenuStateProvider
        uiView.contextMenuActionHandler = onContextMenuAction
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
            targetWidth = max(targetWidth, RubyNoWrapContainerWidth)
        }

        uiView.lastMeasuredBoundsWidth = snappedBaseWidth
        uiView.lastMeasuredTextContainerWidth = targetWidth
        if abs(uiView.textContainer.size.width - targetWidth) > 0.5 {
            uiView.textContainer.size = CGSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
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
        guard attributed.length > 0 else {
            let rubyFont = baseFont.withSize(max(1, defaultRubyFontSize))
            return max(0, rubyFont.lineHeight + rubyBaselineGap)
        }
        let full = NSRange(location: 0, length: attributed.length)
        var maxRubyHeight: CGFloat = 0
        attributed.enumerateAttribute(.rubyReadingFontSize, in: full, options: []) { value, _, _ in
            let rubySize: CGFloat? = {
                if let num = value as? NSNumber { return CGFloat(num.doubleValue) }
                if let cg = value as? CGFloat { return cg }
                if let dbl = value as? Double { return CGFloat(dbl) }
                return nil
            }()
            guard let rubySize, rubySize.isFinite else { return }
            let rubyFont = baseFont.withSize(max(1.0, rubySize))
            maxRubyHeight = max(maxRubyHeight, rubyFont.lineHeight)
        }
        if maxRubyHeight <= 0 {
            let rubyFont = baseFont.withSize(max(1, defaultRubyFontSize))
            maxRubyHeight = rubyFont.lineHeight
        }
        // Reserve the ruby font height plus a small gap to visually separate from the base glyphs.
        return max(0, maxRubyHeight + rubyBaselineGap)
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

    private static func measureTypographicWidth(_ attributed: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func makeWidthAttachmentAttributes(width: CGFloat) -> [NSAttributedString.Key: Any] {
        let w = max(0, width)

        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { ref in
                Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).release()
            },
            getAscent: { ref in
                let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                _ = data
                return 0
            },
            getDescent: { _ in 0 },
            getWidth: { ref in
                let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                return CGFloat(data.doubleValue)
            }
        )

        let boxed = NSNumber(value: Double(w))
        let ref = Unmanaged.passRetained(boxed).toOpaque()
        let delegate = CTRunDelegateCreate(&callbacks, ref)

        return [
            kCTRunDelegateAttributeName as NSAttributedString.Key: delegate as Any,
            .foregroundColor: UIColor.clear
        ]
    }

    static func applyRubyWidthPaddingAroundRunsIfNeeded(
        to attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat,
        enabled: Bool
    ) -> (NSAttributedString, TokenOverlayTextView.RubyIndexMap) {
        guard enabled, attributed.length > 0 else {
            return (attributed, .identity)
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)

        // Insert display-only spacers around ruby-bearing headword runs so base width matches ruby width.
        // We insert exactly one U+FFFC per spacer and use a CTRunDelegate width.
        struct SpacerInsertion {
            let insertAtSourceIndex: Int
            let width: CGFloat
            let rubyReading: String
            let rubyFontSize: CGFloat
        }
        var insertions: [SpacerInsertion] = []
        insertions.reserveCapacity(64)

        mutable.enumerateAttribute(.rubyReadingText, in: full, options: []) { value, range, _ in
            guard let reading = value as? String, reading.isEmpty == false else { return }
            guard range.location != NSNotFound, range.length > 0 else { return }
            guard NSMaxRange(range) <= mutable.length else { return }

            let rubyFontSize: CGFloat = {
                if let stored = mutable.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? Double {
                    return CGFloat(max(1.0, stored))
                }
                if let stored = mutable.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? CGFloat {
                    return max(1.0, stored)
                }
                if let stored = mutable.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? NSNumber {
                    return CGFloat(max(1.0, stored.doubleValue))
                }
                return max(1.0, defaultRubyFontSize)
            }()

            let baseSub = mutable.attributedSubstring(from: range)
            let baseForMeasurement = NSMutableAttributedString(attributedString: baseSub)
            if baseForMeasurement.length > 0,
               baseForMeasurement.attribute(.font, at: 0, effectiveRange: nil) == nil {
                baseForMeasurement.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: baseForMeasurement.length))
            }
            let baseWidth = measureTypographicWidth(baseForMeasurement)

            let rubyFont = baseFont.withSize(max(1.0, rubyFontSize))
            let rubyAttr = NSAttributedString(string: reading, attributes: [.font: rubyFont])
            let rubyWidth = measureTypographicWidth(rubyAttr)

            let overhang = rubyWidth - baseWidth
            guard overhang > 0.25 else { return }

            let pad = overhang / 2
            insertions.append(.init(insertAtSourceIndex: range.location, width: pad, rubyReading: reading, rubyFontSize: rubyFontSize))
            insertions.append(.init(insertAtSourceIndex: NSMaxRange(range), width: pad, rubyReading: reading, rubyFontSize: rubyFontSize))
        }

        guard insertions.isEmpty == false else {
            return (mutable, .identity)
        }

        // Adjacent ruby runs (common when furigana is per-kanji) produce TWO insertions at the
        // same boundary: a right-pad for the left run and a left-pad for the right run.
        // The conservative sum can create huge intra-word gaps (e.g. "純　情").
        // Allow ruby to overhang more by capping the *total* padding at shared boundaries.
        let groupedByIndex = Dictionary(grouping: insertions, by: { $0.insertAtSourceIndex })
        if groupedByIndex.values.contains(where: { $0.count >= 2 }) {
            let capTotalAtSharedBoundary = max(1.0, baseFont.pointSize * 0.28)
            var adjusted: [SpacerInsertion] = []
            adjusted.reserveCapacity(insertions.count)

            for (idx, group) in groupedByIndex {
                if group.count < 2 {
                    adjusted.append(contentsOf: group)
                    continue
                }

                let sum = group.reduce(CGFloat(0)) { $0 + $1.width }
                let scale: CGFloat = (sum > capTotalAtSharedBoundary && sum > 0)
                    ? (capTotalAtSharedBoundary / sum)
                    : 1.0

                for item in group {
                    adjusted.append(
                        .init(
                            insertAtSourceIndex: idx,
                            width: max(0, item.width * scale),
                            rubyReading: item.rubyReading,
                            rubyFontSize: item.rubyFontSize
                        )
                    )
                }
            }

            insertions = adjusted
        }

        // Apply insertions from end to start so indices remain stable.
        let sorted = insertions.sorted {
            if $0.insertAtSourceIndex != $1.insertAtSourceIndex {
                return $0.insertAtSourceIndex > $1.insertAtSourceIndex
            }
            return $0.width > $1.width
        }

        for item in sorted {
            let attachmentChar = "\u{FFFC}" // object replacement character
            let attrs = makeWidthAttachmentAttributes(width: item.width)
            let insert = NSMutableAttributedString(string: attachmentChar, attributes: attrs)
            insert.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: insert.length))
            // Extend ruby attributes across the spacers so the ruby run's measured base width includes padding.
            insert.addAttribute(.rubyReadingText, value: item.rubyReading, range: NSRange(location: 0, length: insert.length))
            insert.addAttribute(.rubyReadingFontSize, value: item.rubyFontSize, range: NSRange(location: 0, length: insert.length))

            let safeIndex = max(0, min(mutable.length, item.insertAtSourceIndex))
            mutable.insert(insert, at: safeIndex)
        }

        let insertionPositions = insertions.map { $0.insertAtSourceIndex }.sorted()
        return (mutable, TokenOverlayTextView.RubyIndexMap(insertionPositions: insertionPositions))
    }
}

final class TokenOverlayTextView: UITextView, UIContextMenuInteractionDelegate {
    // NOTE: Avoid TextKit 1 entry points (`layoutManager`, `textStorage`, `glyphRange(...)`, etc.).
    // Geometry for highlights + ruby anchoring is derived via TextKit 2 (`textLayoutManager`)
    // with `selectionRects(for:)` as a UI-safe fallback.

    struct RubyIndexMap: Equatable {
        // In SOURCE coordinates, each value indicates a 1-UTF16-unit insertion position.
        // (We insert exactly one U+FFFC per spacer.) Duplicates are allowed.
        let insertionPositions: [Int]

        static let identity = RubyIndexMap(insertionPositions: [])

        private func lowerBound(_ value: Int) -> Int {
            // First index where insertionPositions[index] >= value
            var low = 0
            var high = insertionPositions.count
            while low < high {
                let mid = (low + high) / 2
                if insertionPositions[mid] < value {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        private func upperBound(_ value: Int) -> Int {
            // First index where insertionPositions[index] > value
            var low = 0
            var high = insertionPositions.count
            while low < high {
                let mid = (low + high) / 2
                if insertionPositions[mid] <= value {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            return low
        }

        func sourceToDisplay(_ sourceIndex: Int, includeInsertionsAtIndex: Bool) -> Int {
            guard insertionPositions.isEmpty == false else { return sourceIndex }
            let count: Int = includeInsertionsAtIndex
                ? upperBound(sourceIndex) // <= sourceIndex
                : lowerBound(sourceIndex) // < sourceIndex
            return sourceIndex + count
        }

        func displayToSource(_ displayIndex: Int) -> Int {
            guard insertionPositions.isEmpty == false else { return displayIndex }
            let target = max(0, displayIndex)

            // Find the largest source index such that sourceToDisplay(source) <= display.
            // This maps inserted spacer indices to the nearest preceding source index.
            var low = 0
            var high = target
            while low < high {
                let mid = (low + high + 1) / 2
                let mapped = sourceToDisplay(mid, includeInsertionsAtIndex: true)
                if mapped <= target {
                    low = mid
                } else {
                    high = mid - 1
                }
            }
            return low
        }

        func sourceRangeToDisplay(_ range: NSRange) -> NSRange {
            guard range.location != NSNotFound, range.length > 0 else { return range }
            let start = sourceToDisplay(range.location, includeInsertionsAtIndex: true)
            let end = sourceToDisplay(NSMaxRange(range), includeInsertionsAtIndex: false)
            return NSRange(location: start, length: max(0, end - start))
        }
    }

    final class RubyHeadroomLayoutFragment: NSTextLayoutFragment {
        var rubyHeadroom: CGFloat = 0

        // Reserve space above the first line in this fragment.
        // This is the supported custom-spacing hook for fragment layout.
        override var topMargin: CGFloat {
            max(super.topMargin, rubyHeadroom)
        }

        // Expand rendering bounds so any ruby drawn into the reserved headroom isn't clipped.
        override var renderingSurfaceBounds: CGRect {
            var b = super.renderingSurfaceBounds
            let h = max(0, rubyHeadroom)
            b.origin.y -= h
            b.size.height += h
            return b
        }
    }

    var rubyIndexMap: RubyIndexMap = .identity {
        didSet {
            guard oldValue != rubyIndexMap else { return }
            rebuildPreferredWrapBreakIndicesIfNeeded()
            if headwordDebugRectsEnabled {
                updateHeadwordDebugRects()
            }
            updateHeadwordBoundingRects()
            setNeedsLayout()
        }
    }

    // Extra vertical headroom reserved via custom TextKit 2 layout fragments.
    // This avoids paragraph-style hacks and ensures ruby never overlaps the previous line.
    var rubyReservedTopMargin: CGFloat = 0 {
        didSet {
            guard abs(oldValue - rubyReservedTopMargin) > 0.5 else { return }
            rubyOverlayDirty = true
            setNeedsLayout()
            if let tlm = textLayoutManager {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
        }
    }

    func displayIndex(fromSourceIndex sourceIndex: Int, includeInsertionsAtIndex: Bool = true) -> Int {
        rubyIndexMap.sourceToDisplay(sourceIndex, includeInsertionsAtIndex: includeInsertionsAtIndex)
    }

    func sourceIndex(fromDisplayIndex displayIndex: Int) -> Int {
        rubyIndexMap.displayToSource(displayIndex)
    }

    func displayRange(fromSourceRange range: NSRange) -> NSRange {
        rubyIndexMap.sourceRangeToDisplay(range)
    }

    func sourceRange(fromDisplayRange range: NSRange) -> NSRange {
        guard range.location != NSNotFound, range.length > 0 else { return range }
        let startSource = sourceIndex(fromDisplayIndex: range.location)
        let lastDisplayIndex = max(range.location, NSMaxRange(range) - 1)
        let lastSource = sourceIndex(fromDisplayIndex: lastDisplayIndex)
        let endSourceExclusive = lastSource + 1
        return NSRange(location: startSource, length: max(0, endSourceExclusive - startSource))
    }

    var semanticSpans: [SemanticSpan] = [] {
        didSet {
            rebuildPreferredWrapBreakIndicesIfNeeded()
            if headwordDebugRectsEnabled {
                updateHeadwordDebugRects()
            }
            updateHeadwordBoundingRects()
            // Keep debug overlays and token hit-testing in sync without requiring the
            // headword debug toggle to be active.
            setNeedsLayout()
        }
    }

    private var preferredWrapBreakIndices: Set<Int> = []
    private var preferredWrapBreakSignature: Int = 0

    private func rebuildPreferredWrapBreakIndicesIfNeeded() {
        guard wrapLines else {
            preferredWrapBreakIndices = []
            preferredWrapBreakSignature = 0
            return
        }
        let length = attributedText?.length ?? 0

        var hasher = Hasher()
        hasher.combine(length)
        hasher.combine(semanticSpans.count)
        // Sample a few spans to avoid hashing the entire array on every update.
        if semanticSpans.isEmpty == false {
            hasher.combine(semanticSpans[0].range.location)
            hasher.combine(semanticSpans[0].range.length)
            let mid = semanticSpans.count / 2
            hasher.combine(semanticSpans[mid].range.location)
            hasher.combine(semanticSpans[mid].range.length)
            let last = semanticSpans.count - 1
            hasher.combine(semanticSpans[last].range.location)
            hasher.combine(semanticSpans[last].range.length)
        }
        let signature = hasher.finalize()
        guard signature != preferredWrapBreakSignature else { return }
        preferredWrapBreakSignature = signature

        guard length > 0 else {
            preferredWrapBreakIndices = []
            return
        }

        var indices: Set<Int> = []
        indices.reserveCapacity(min(semanticSpans.count, 256))
        for span in semanticSpans {
            let loc = span.range.location
            guard loc != NSNotFound else { continue }
            let displayLoc = displayIndex(fromSourceIndex: loc, includeInsertionsAtIndex: true)
            if displayLoc > 0 && displayLoc < length {
                indices.insert(displayLoc)
            }
        }
        preferredWrapBreakIndices = indices
    }

    private func shouldAllowWordBreakBeforeCharacter(at charIndex: Int) -> Bool {
        guard wrapLines else { return true }
        rebuildPreferredWrapBreakIndicesIfNeeded()
        guard preferredWrapBreakIndices.isEmpty == false else { return true }

        if preferredWrapBreakIndices.contains(charIndex) {
            if isRubyWidthSpacer(atDisplayIndex: charIndex - 1) {
                return false
            }
            return true
        }

        // Ruby headword padding uses invisible width spacer characters (U+FFFC with a CTRunDelegate).
        // We must NOT create new generic breakpoints at spacer positions (that can split tokens).
        // Instead, only allow breaking BEFORE a *leading* spacer run when it immediately precedes
        // an allowed token boundary.
        if isRubyWidthSpacer(atDisplayIndex: charIndex) {
            let nextNonSpacer = nextNonSpacerDisplayIndex(startingAt: charIndex)
            if nextNonSpacer != charIndex,
               preferredWrapBreakIndices.contains(nextNonSpacer),
               isLeadingRubyWidthSpacerRun(startingAt: charIndex, nextNonSpacer: nextNonSpacer) {
                return true
            }
        }

        // Always allow natural breaks after real whitespace/newlines.
        let ns = (attributedText?.string ?? "") as NSString
        if ns.length > 0 {
            let prevIndex = min(max(0, charIndex - 1), max(0, ns.length - 1))
            let prevRange = ns.rangeOfComposedCharacterSequence(at: prevIndex)
            if prevRange.location != NSNotFound,
               prevRange.length > 0,
               NSMaxRange(prevRange) <= ns.length {
                let prev = ns.substring(with: prevRange)
                if prev.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
            }
        }

        return false
    }

    private func isRubyWidthSpacer(atDisplayIndex displayIndex: Int) -> Bool {
        guard let attributedText else { return false }
        let i = displayIndex
        guard i >= 0, i < attributedText.length else { return false }

        // Fast path: our spacers always use a CTRunDelegate for width.
        if attributedText.attribute(kCTRunDelegateAttributeName as NSAttributedString.Key, at: i, effectiveRange: nil) != nil {
            return true
        }

        // Fallback: also treat raw object-replacement as spacer.
        let ns = attributedText.string as NSString
        guard ns.length > 0, i < ns.length else { return false }
        return ns.character(at: i) == 0xFFFC
    }

    private func nextNonSpacerDisplayIndex(startingAt displayIndex: Int) -> Int {
        guard let attributedText else { return displayIndex }
        var i = max(0, displayIndex)
        let upper = attributedText.length
        while i < upper, isRubyWidthSpacer(atDisplayIndex: i) {
            i += 1
        }
        return i
    }

    private func hasRubyReadingAttribute(atDisplayIndex displayIndex: Int) -> Bool {
        guard let attributedText else { return false }
        let i = displayIndex
        guard i >= 0, i < attributedText.length else { return false }
        return attributedText.attribute(.rubyReadingText, at: i, effectiveRange: nil) != nil
    }

    private func isLeadingRubyWidthSpacerRun(startingAt spacerIndex: Int, nextNonSpacer: Int) -> Bool {
        // Leading spacer(s): immediately followed by a ruby-bearing headword character.
        // Trailing spacer(s): immediately preceded by a ruby-bearing headword character.
        guard hasRubyReadingAttribute(atDisplayIndex: nextNonSpacer) else { return false }

        // Find the previous non-spacer character (if any) so we can reject trailing spacers.
        var prev = spacerIndex - 1
        while prev >= 0, isRubyWidthSpacer(atDisplayIndex: prev) {
            prev -= 1
        }
        if prev >= 0, hasRubyReadingAttribute(atDisplayIndex: prev) {
            return false
        }
        return true
    }

    @available(iOS 15.0, *)
    private func ensureTextKit2DelegateInstalled() {
        // UITextView can create TextKit 2 objects lazily; make sure our delegate
        // is attached whenever the layout manager is available.
        if let tlm = textLayoutManager, tlm.delegate !== self {
            tlm.delegate = self
        }
    }

    var viewMetricsContext: RubyText.ViewMetricsContext? {
        didSet {
            guard viewMetricsHUDEnabled else { return }
            if oldValue != viewMetricsContext {
                setNeedsLayout()
            }
        }
    }

    var alternateTokenColorsEnabled: Bool = false {
        didSet {
            guard oldValue != alternateTokenColorsEnabled else { return }
            updateDebugBoundingStrokeAppearance()
        }
    }

    var tokenColorPalette: [UIColor] = [] {
        didSet {
            guard TokenOverlayTextView.colorsEquivalent(tokenColorPalette, oldValue) == false else { return }
            updateDebugBoundingStrokeAppearance()
        }
    }

    private static func colorsEquivalent(_ lhs: [UIColor], _ rhs: [UIColor]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            if left.isEqual(right) == false { return false }
        }
        return true
    }

    private static func emphasizedDebugStrokeColor(from color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let mix: (CGFloat) -> CGFloat = { min(1.0, $0 * 0.85 + 0.15) }
            let targetAlpha = max(0.85, alpha)
            return UIColor(red: mix(red), green: mix(green), blue: mix(blue), alpha: targetAlpha)
        }
        let fallbackAlpha = max(0.85, color.cgColor.alpha)
        return color.withAlphaComponent(fallbackAlpha)
    }

    // Cache a lightweight signature of the last fully applied attributed rendering.
    // This helps avoid reassigning `attributedText` on highlight-only updates.
    fileprivate var lastAppliedRenderKey: Int? = nil

    // Vertical gap between the headword and ruby text.
    var rubyBaselineGap: CGFloat = 1.0

    var rubyHorizontalAlignment: RubyHorizontalAlignment = .center {
        didSet {
            guard oldValue != rubyHorizontalAlignment else { return }
            rubyOverlayDirty = true
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    var padHeadwordSpacing: Bool = false {
        didSet {
            guard oldValue != padHeadwordSpacing else { return }
            rubyOverlayDirty = true
            setNeedsLayout()
        }
    }

    private func caretXRangeInViewCoordinates(for characterRange: NSRange) -> (startX: CGFloat, endX: CGFloat)? {
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return nil }
        guard let attributedText, attributedText.length > 0 else { return nil }
        guard NSMaxRange(characterRange) <= attributedText.length else { return nil }

        guard let start = position(from: beginningOfDocument, offset: characterRange.location),
              let end = position(from: start, offset: characterRange.length) else {
            return nil
        }

        // `caretRect(for:)` is in VIEW coordinates (origin at 0,0), not content coordinates.
        // It includes the actual laid-out advance width, including `.kern`.
        let a = caretRect(for: start)
        let b = caretRect(for: end)

        // If the range spans multiple visual lines, caret X range is not meaningful.
        let yTolerance: CGFloat = 2.0
        if abs(a.midY - b.midY) > yTolerance {
            return nil
        }

        let startX = min(a.minX, b.minX)
        let endX = max(a.minX, b.minX)
        return (startX: startX, endX: endX)
    }

    private func caretXRangeInContentCoordinates(for characterRange: NSRange) -> (startX: CGFloat, endX: CGFloat)? {
        guard let xr = caretXRangeInViewCoordinates(for: characterRange) else { return nil }
        // Convert view → content coordinates for scroll-view overlay layers.
        return (startX: xr.startX + contentOffset.x, endX: xr.endX + contentOffset.x)
    }

    var rubyAnnotationVisibility: RubyAnnotationVisibility = .visible {
        didSet {
            guard oldValue != rubyAnnotationVisibility else { return }
            needsHighlightUpdate = true
            rubyOverlayDirty = true
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
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("selectionHighlightRange didSet -> setNeedsLayout (range=\(String(describing: selectionHighlightRange)))")
            }
        }
    }

    var selectionHighlightInsets: UIEdgeInsets = .zero {
        didSet {
            guard oldValue != selectionHighlightInsets else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug(String(format: "selectionHighlightInsets didSet -> setNeedsLayout (top=%.2f left=%.2f bottom=%.2f right=%.2f)", selectionHighlightInsets.top, selectionHighlightInsets.left, selectionHighlightInsets.bottom, selectionHighlightInsets.right))
            }
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
            rubyOverlayDirty = true
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
            rubyOverlayDirty = true
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
    private let highlightOverlayContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        return layer
    }()
    private let baseHighlightLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemYellow.withAlphaComponent(0.38).cgColor
        layer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.75).cgColor
        layer.lineWidth = 1.0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    private let rubyHighlightLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemYellow.withAlphaComponent(0.25).cgColor
        layer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.55).cgColor
        layer.lineWidth = 1.0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    var rubyHighlightHeadroom: CGFloat = 0 {
        didSet {
            guard oldValue != rubyHighlightHeadroom else { return }
            needsHighlightUpdate = true
            setNeedsLayout()
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug(String(format: "rubyHighlightHeadroom didSet -> setNeedsLayout (headroom=%.2f)", rubyHighlightHeadroom))
            }
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
    private var isClampingHorizontalOffset: Bool = false

    // Strategy 1: persistent overlay layers for ruby readings.
    // These layers are positioned during layout and then scroll automatically with the UITextView.
    private let rubyOverlayContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        return layer
    }()
    private var rubyOverlayDirty: Bool = true
    private var lastRubyOverlayLayoutSignature: Int = 0

    // NOTE: TextKit 2 segment rects have proven to be coordinate-space sensitive.
    // Keep this off by default until fully verified across devices/simulator.
    private static let useTextKit2RubyAnchorRects: Bool = {
        ProcessInfo.processInfo.environment["RUBY_TK2_ANCHORS"] == "1"
    }()

    private static let verboseRubyLoggingEnabled: Bool = {
        ProcessInfo.processInfo.environment["RUBY_TRACE"] == "1"
    }()

    private static let legacyRubyDebugHUDDefaultsKey = "rubyDebugHUD"
    private static let viewMetricsHUDDefaultsKey = "debugViewMetricsHUD"
    private static let rubyDebugRectsDefaultsKey = "rubyDebugRects"
    private static let headwordDebugRectsDefaultsKey = "rubyHeadwordDebugRects"
    private static let rubyDebugLineBandsDefaultsKey = "rubyDebugLineBands"
    private static let headwordLineBandsDefaultsKey = "rubyHeadwordLineBands"
    private static let rubyLineBandsDefaultsKey = "rubyFuriganaLineBands"

    private var viewMetricsHUDEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.viewMetricsHUDDefaultsKey) != nil {
            return defaults.bool(forKey: Self.viewMetricsHUDDefaultsKey)
        }
        return defaults.bool(forKey: Self.legacyRubyDebugHUDDefaultsKey)
    }

    private var rubyDebugRectsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.rubyDebugRectsDefaultsKey)
    }

    private var headwordDebugRectsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.headwordDebugRectsDefaultsKey)
    }

    private var headwordLineBandsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.headwordLineBandsDefaultsKey)
    }

    private var rubyLineBandsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.rubyLineBandsDefaultsKey)
    }

    private lazy var viewMetricsHUDLabel: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = UIColor.white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.isUserInteractionEnabled = false
        return label
    }()

    private var userDefaultsObserver: NSObjectProtocol? = nil
    private var lastTextContainerIdentity: ObjectIdentifier? = nil

    private struct DebugColorKey: Hashable {
        let red: UInt16
        let green: UInt16
        let blue: UInt16
        let alpha: UInt16

        init(color: UIColor) {
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            if color.getRed(&r, green: &g, blue: &b, alpha: &a) == false {
                if let components = color.cgColor.components {
                    switch components.count {
                    case 2:
                        r = components[0]
                        g = components[0]
                        b = components[0]
                        a = components[1]
                    case 3:
                        r = components[0]
                        g = components[1]
                        b = components[2]
                        a = color.cgColor.alpha
                    case 4...:
                        r = components[0]
                        g = components[1]
                        b = components[2]
                        a = components[3]
                    default:
                        r = 0
                        g = 0
                        b = 0
                        a = 1
                    }
                }
            }
            func quantize(_ component: CGFloat) -> UInt16 {
                let clamped = max(0, min(1, component))
                return UInt16(clamping: Int(round(clamped * 1000)))
            }
            self.red = quantize(r)
            self.green = quantize(g)
            self.blue = quantize(b)
            self.alpha = quantize(a)
        }
    }

    private let rubyDebugRectsLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = RubyDebugBoundingDefaultStrokeColor.cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = RubyDebugBoundingDashPattern
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        return layer
    }()

    private let headwordBoundingRectsLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.black.withAlphaComponent(0.75).cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = RubyDebugBoundingDashPattern
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        layer.zPosition = 40
        return layer
    }()

    private let headwordDebugRectsContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.actions = [
            "sublayers": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        return layer
    }()

    private var headwordDebugRectLayers: [DebugColorKey: CAShapeLayer] = [:]

    private let rubyDebugLineBandsContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull(),
            "sublayers": NSNull()
        ]
        layer.isHidden = true
        return layer
    }()

    private let rubyDebugGlyphBoundsContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.actions = [
            "sublayers": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        return layer
    }()

    private var rubyDebugGlyphLayers: [DebugColorKey: CAShapeLayer] = [:]

    private func installHeadwordDebugContainerIfNeeded() {
        if headwordDebugRectsContainerLayer.superlayer == nil {
            headwordDebugRectsContainerLayer.contentsScale = traitCollection.displayScale
            headwordDebugRectsContainerLayer.zPosition = 45
            layer.addSublayer(headwordDebugRectsContainerLayer)
        }
    }

    private func installRubyDebugGlyphContainerIfNeeded() {
        if rubyDebugGlyphBoundsContainerLayer.superlayer == nil {
            rubyDebugGlyphBoundsContainerLayer.contentsScale = traitCollection.displayScale
            rubyDebugGlyphBoundsContainerLayer.zPosition = 60
            layer.addSublayer(rubyDebugGlyphBoundsContainerLayer)
        }
    }

    private func resolvedDisplayColor(_ color: UIColor) -> UIColor {
        if #available(iOS 13.0, *) {
            return color.resolvedColor(with: traitCollection)
        }
        return color
    }

    private func sanitizedStrokeColor(from color: UIColor?) -> UIColor? {
        guard let color else { return nil }
        let resolved = resolvedDisplayColor(color)
        guard resolved.cgColor.alpha > 0 else { return nil }
        return Self.emphasizedDebugStrokeColor(from: resolved)
    }

    private func makeDebugShapeLayer(zPosition: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = RubyDebugBoundingDashPattern
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        layer.zPosition = zPosition
        return layer
    }

    private func applyDebugPaths(
        _ pathsByKey: [DebugColorKey: CGMutablePath],
        colorsByKey: [DebugColorKey: UIColor],
        storage: inout [DebugColorKey: CAShapeLayer],
        container: CALayer,
        frame: CGRect,
        zPosition: CGFloat
    ) {
        let activeKeys = Set(pathsByKey.keys)
        let staleKeys = Set(storage.keys).subtracting(activeKeys)
        for key in staleKeys {
            if let layer = storage[key] {
                layer.removeFromSuperlayer()
            }
            storage.removeValue(forKey: key)
        }

        container.frame = frame
        for (key, path) in pathsByKey {
            guard let color = colorsByKey[key] else { continue }
            let layer: CAShapeLayer
            if let existing = storage[key] {
                layer = existing
            } else {
                let newLayer = makeDebugShapeLayer(zPosition: zPosition)
                container.addSublayer(newLayer)
                storage[key] = newLayer
                layer = newLayer
            }
            layer.strokeColor = color.cgColor
            layer.frame = container.bounds
            layer.path = path.isEmpty ? nil : path
            layer.isHidden = path.isEmpty
        }

        container.isHidden = pathsByKey.isEmpty
    }

    private func resetHeadwordDebugLayers() {
        for (_, layer) in headwordDebugRectLayers {
            layer.removeFromSuperlayer()
        }
        headwordDebugRectLayers.removeAll()
        headwordDebugRectsContainerLayer.isHidden = true
    }

    private func resetRubyDebugGlyphLayers() {
        for (_, layer) in rubyDebugGlyphLayers {
            layer.removeFromSuperlayer()
        }
        rubyDebugGlyphLayers.removeAll()
        rubyDebugGlyphBoundsContainerLayer.isHidden = true
    }

    private func resolvedColorForSemanticSpan(_ span: SemanticSpan) -> UIColor? {
        guard let attributedText, attributedText.length > 0 else { return nil }
        let documentRange = NSRange(location: 0, length: attributedText.length)
        let bounded = NSIntersectionRange(displayRange(fromSourceRange: span.range), documentRange)
        guard bounded.length > 0 else { return nil }

        let backing = attributedText.string as NSString
        let sampleLimit = min(bounded.length, 64)
        for offset in 0..<sampleLimit {
            let idx = bounded.location + offset
            if idx >= attributedText.length { break }
            let character = backing.character(at: idx)
            if let scalar = UnicodeScalar(character),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if let color = attributedText.attribute(.foregroundColor, at: idx, effectiveRange: nil) as? UIColor {
                return resolvedDisplayColor(color)
            }
        }

        if let fallback = attributedText.attribute(.foregroundColor, at: bounded.location, effectiveRange: nil) as? UIColor {
            return resolvedDisplayColor(fallback)
        }
        return resolvedDisplayColor(textColor ?? UIColor.label)
    }

    private let baseLineEvenLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        // Even/odd parity is the primary grouping; keep base+ruby the same hue per parity.
        layer.fillColor = UIColor.systemCyan.withAlphaComponent(0.22).cgColor
        layer.strokeColor = nil
        layer.lineWidth = 0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    private let baseLineOddLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemPink.withAlphaComponent(0.22).cgColor
        layer.strokeColor = nil
        layer.lineWidth = 0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    private let rubyBandEvenLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemCyan.withAlphaComponent(0.14).cgColor
        layer.strokeColor = nil
        layer.lineWidth = 0
        layer.lineDashPattern = nil
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    private let rubyBandOddLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemPink.withAlphaComponent(0.14).cgColor
        layer.strokeColor = nil
        layer.lineWidth = 0
        layer.lineDashPattern = nil
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    private let rubyDebugLineBandsLabelsLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        layer.actions = [
            "sublayers": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    override var contentOffset: CGPoint {
        didSet {
            let allowHorizontal = horizontalScrollEnabled && (wrapLines == false)

            // When lines wrap, horizontal motion is never meaningful and often manifests as
            // rubber-banding. Keep vertical bounce, but clamp horizontal offset.
            if allowHorizontal == false {
                if isClampingHorizontalOffset == false {
                    let inset = adjustedContentInset
                    let minX = -inset.left
                    let maxX = max(minX, contentSize.width - bounds.width + inset.right)
                    let clampedX = min(max(contentOffset.x, minX), maxX)
                    if abs(contentOffset.x - clampedX) > 0.5 {
                        isClampingHorizontalOffset = true
                        setContentOffset(CGPoint(x: clampedX, y: contentOffset.y), animated: false)
                        isClampingHorizontalOffset = false
                        return
                    }
                }
            }

            // Highlights/ruby overlays are content-space overlays; UIKit scrolls them automatically.
            // Do not update highlight geometry during scroll.

            // Debug overlays:
            // - HUD is a UIView inside a UIScrollView; keep it pinned to the viewport by
            //   positioning it relative to `contentOffset`.
            // - Line bands are viewport-derived (TextKit 2 is often viewport-lazy), so update
            //   them on scroll, but coalesce to the next runloop.
            if viewMetricsHUDEnabled {
                updateViewMetricsHUD()
            }
            if headwordLineBandsEnabled || rubyLineBandsEnabled || rubyDebugRectsEnabled {
                scheduleDebugOverlaysUpdate()
            }
            warmVisibleSemanticSpanLayoutIfNeeded()
        }
    }

    private func scheduleDebugOverlaysUpdate() {
        guard scrollRedrawScheduled == false else { return }
        scrollRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollRedrawScheduled = false

            if self.headwordLineBandsEnabled || self.rubyLineBandsEnabled {
                self.updateRubyDebugLineBands()
            }
            if self.rubyDebugRectsEnabled {
                self.updateRubyDebugRects()
                self.updateRubyDebugGlyphBounds()
            }
        }
    }

    private func updateDebugBoundingStrokeAppearance() {
        let strokeColor = resolvedDebugStrokeColor(at: 0) ?? resolvedDebugBoundingStrokeColor()
        rubyDebugRectsLayer.strokeColor = strokeColor.cgColor
        rubyDebugRectsLayer.lineDashPattern = RubyDebugBoundingDashPattern

        if headwordDebugRectsEnabled {
            updateHeadwordDebugRects()
        }
        if rubyDebugRectsEnabled {
            updateRubyDebugGlyphBounds()
        }
    }

    private func resolvedDebugBoundingStrokeColor() -> UIColor {
        if traitCollection.userInterfaceStyle == .dark && alternateTokenColorsEnabled == false {
            return RubyDebugBoundingDarkModeStrokeColor
        }
        return RubyDebugBoundingDefaultStrokeColor
    }

    private func resolvedDebugStrokeColor(at index: Int) -> UIColor? {
        guard alternateTokenColorsEnabled else { return nil }
        guard index >= 0 && index < tokenColorPalette.count else { return nil }
        return TokenOverlayTextView.emphasizedDebugStrokeColor(from: tokenColorPalette[index])
    }

    private func scheduleScrollRedraw() {
        // No-op (legacy). Ruby rendering no longer depends on scroll-time redraws.
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
            if textContainer.size.width < RubyNoWrapContainerWidth {
                textContainer.size = CGSize(width: RubyNoWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }

    private func updateHorizontalScrollConfig() {
        // Match editor behavior: allow vertical bounce even when content is short,
        // so overscroll can be synchronized between panes.
        alwaysBounceVertical = true
        let allowHorizontal = horizontalScrollEnabled && (wrapLines == false)
        alwaysBounceHorizontal = allowHorizontal
        showsHorizontalScrollIndicator = allowHorizontal
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
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.maximumNumberOfLines = 0
        textContainer.lineBreakMode = .byWordWrapping
        if #available(iOS 15.0, *) {
            ensureTextKit2DelegateInstalled()
        }
        textContainerInset = .zero
        clipsToBounds = true
        layer.masksToBounds = true

        // Strategy 1: persistent ruby overlay layers that move with UIScrollView bounds changes.
        // These layers are positioned during layout (not during scroll).
        rubyOverlayContainerLayer.contentsScale = traitCollection.displayScale
        rubyOverlayContainerLayer.zPosition = 10
        rubyOverlayContainerLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "sublayers": NSNull(),
            "contents": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.addSublayer(rubyOverlayContainerLayer)

        // Persistent highlight overlays (content-space, like ruby overlays).
        highlightOverlayContainerLayer.contentsScale = traitCollection.displayScale
        highlightOverlayContainerLayer.zPosition = 5
        highlightOverlayContainerLayer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "sublayers": NSNull(),
            "contents": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        baseHighlightLayer.contentsScale = traitCollection.displayScale
        rubyHighlightLayer.contentsScale = traitCollection.displayScale
        highlightOverlayContainerLayer.addSublayer(rubyHighlightLayer)
        highlightOverlayContainerLayer.addSublayer(baseHighlightLayer)
        layer.addSublayer(highlightOverlayContainerLayer)

        headwordBoundingRectsLayer.contentsScale = traitCollection.displayScale
        layer.addSublayer(headwordBoundingRectsLayer)

        if viewMetricsHUDEnabled {
            addSubview(viewMetricsHUDLabel)
            viewMetricsHUDLabel.isHidden = false
        }
        if rubyDebugRectsEnabled {
            rubyDebugRectsLayer.contentsScale = traitCollection.displayScale
            rubyDebugRectsLayer.zPosition = 50
            layer.addSublayer(rubyDebugRectsLayer)
            rubyDebugRectsLayer.isHidden = false
            installRubyDebugGlyphContainerIfNeeded()
        }

        if headwordDebugRectsEnabled {
            installHeadwordDebugContainerIfNeeded()
        }

        if headwordLineBandsEnabled || rubyLineBandsEnabled {
            rubyDebugLineBandsContainerLayer.contentsScale = traitCollection.displayScale
            rubyDebugLineBandsContainerLayer.zPosition = 2
            rubyDebugLineBandsContainerLayer.addSublayer(rubyBandEvenLayer)
            rubyDebugLineBandsContainerLayer.addSublayer(rubyBandOddLayer)
            rubyDebugLineBandsContainerLayer.addSublayer(baseLineEvenLayer)
            rubyDebugLineBandsContainerLayer.addSublayer(baseLineOddLayer)
            rubyDebugLineBandsContainerLayer.addSublayer(rubyDebugLineBandsLabelsLayer)
            layer.addSublayer(rubyDebugLineBandsContainerLayer)
            rubyDebugLineBandsContainerLayer.isHidden = false
        }

        // SettingsView toggles write via @AppStorage -> UserDefaults.
        // Without a re-layout, these overlays may not appear until a later geometry change.
        if userDefaultsObserver == nil {
            userDefaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }

        updateDebugBoundingStrokeAppearance()
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

    deinit {
        if let userDefaultsObserver {
            NotificationCenter.default.removeObserver(userDefaultsObserver)
        }
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

        if #available(iOS 15.0, *) {
            ensureTextKit2DelegateInstalled()
        }

        // UIKit may replace/reinitialize the underlying text container during runtime.
        // If that happens, reapply our required container settings immediately.
        let currentIdentity = ObjectIdentifier(textContainer)
        if lastTextContainerIdentity != currentIdentity {
            lastTextContainerIdentity = currentIdentity
            applyStableTextContainerConfig()
        } else if textContainer.widthTracksTextView != false {
            applyStableTextContainerConfig()
        }

        if Self.verboseRubyLoggingEnabled {
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
            CustomLogger.shared.debug(
                String(
                    format: "PASS layoutSubviews bounds=%.2fx%.2f textContainer=%.2fx%.2f contentSizeH=%.2f scroll=%@ tracksWidth=%@ tcID=%d ruby=%@",
                    b.width,
                    b.height,
                    tcSize.width,
                    tcSize.height,
                    csH,
                    scroll ? "true" : "false",
                    tracks ? "true" : "false",
                    tcID,
                    vis
                )
            )
        }

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

        warmVisibleSemanticSpanLayoutIfNeeded()

        // Ruby highlight geometry is derived from the ruby overlay layers.
        // Ensure overlays are laid out first so highlight rects can match actual ruby bounds.
        layoutRubyOverlayIfNeeded()

        // Highlights are content-space overlays; keep their container sized to content.
        // This avoids stale frames when contentSize changes but selection does not.
        highlightOverlayContainerLayer.frame = CGRect(origin: .zero, size: contentSize)

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

        updateHeadwordBoundingRects()

        if viewMetricsHUDEnabled {
            if viewMetricsHUDLabel.superview == nil {
                addSubview(viewMetricsHUDLabel)
            }
            updateViewMetricsHUD()
            viewMetricsHUDLabel.isHidden = false
        } else {
            viewMetricsHUDLabel.isHidden = true
        }
        if rubyDebugRectsEnabled {
            if rubyDebugRectsLayer.superlayer == nil {
                rubyDebugRectsLayer.contentsScale = traitCollection.displayScale
                rubyDebugRectsLayer.zPosition = 50
                layer.addSublayer(rubyDebugRectsLayer)
            }
            installRubyDebugGlyphContainerIfNeeded()
            updateRubyDebugRects()
            updateRubyDebugGlyphBounds()
            rubyDebugRectsLayer.isHidden = false
        } else {
            rubyDebugRectsLayer.path = nil
            rubyDebugRectsLayer.isHidden = true
            resetRubyDebugGlyphLayers()
        }

        if headwordDebugRectsEnabled {
            installHeadwordDebugContainerIfNeeded()
            updateHeadwordDebugRects()
        } else {
            resetHeadwordDebugLayers()
        }

        let wantsLineBands = headwordLineBandsEnabled || rubyLineBandsEnabled
        if wantsLineBands {
            if rubyDebugLineBandsContainerLayer.superlayer == nil {
                rubyDebugLineBandsContainerLayer.contentsScale = traitCollection.displayScale
                rubyDebugLineBandsContainerLayer.zPosition = 2
                rubyDebugLineBandsLabelsLayer.contentsScale = traitCollection.displayScale
                rubyDebugLineBandsContainerLayer.addSublayer(rubyBandEvenLayer)
                rubyDebugLineBandsContainerLayer.addSublayer(rubyBandOddLayer)
                rubyDebugLineBandsContainerLayer.addSublayer(baseLineEvenLayer)
                rubyDebugLineBandsContainerLayer.addSublayer(baseLineOddLayer)
                rubyDebugLineBandsContainerLayer.addSublayer(rubyDebugLineBandsLabelsLayer)
                layer.addSublayer(rubyDebugLineBandsContainerLayer)
            }
            updateRubyDebugLineBands()
            rubyDebugLineBandsContainerLayer.isHidden = false
        } else {
            baseLineEvenLayer.path = nil
            baseLineOddLayer.path = nil
            rubyBandEvenLayer.path = nil
            rubyBandOddLayer.path = nil
            rubyDebugLineBandsLabelsLayer.sublayers = nil
            rubyDebugLineBandsContainerLayer.isHidden = true
        }

    }

    @available(iOS, deprecated: 17.0, message: "Use UITraitChangeObservable APIs once iOS 17+ only.")
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateDebugBoundingStrokeAppearance()
        }
    }

    private func updateViewMetricsHUD() {
        guard viewMetricsHUDLabel.superview != nil else { return }

        let inset = textContainerInset
        let offset = contentOffset
        let cs = contentSize
        let b = bounds
        let measuredW = lastMeasuredBoundsWidth
        let measuredTCW = lastMeasuredTextContainerWidth
        let rubyLayerCount = rubyOverlayContainerLayer.sublayers?.count ?? 0

        let sel: String = {
            let r = selectedRange
            if r.location == NSNotFound { return "sel=none" }
            return "sel=\(r.location),\(r.length)"
        }()

        let vis: String = {
            switch rubyAnnotationVisibility {
            case .visible: return "ruby=vis"
            case .hiddenKeepMetrics: return "ruby=hiddenMetrics"
            case .removed: return "ruby=removed"
            }
        }()

        func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
        var lines: [String] = [
            "\(vis) runs=\(cachedRubyRuns.count) layers=\(rubyLayerCount)",
            "b=\(f(b.width))x\(f(b.height)) cs=\(f(cs.width))x\(f(cs.height))",
            "off=\(f(offset.x)),\(f(offset.y)) insetT=\(f(inset.top))",
            "tcW=\(f(textContainer.size.width)) mW=\(f(measuredW)) mTCW=\(f(measuredTCW))",
            "headroom=\(f(rubyHighlightHeadroom)) gap=\(f(rubyBaselineGap)) \(sel)"
        ]

        if let metrics = viewMetricsContext {
            if let paste = metrics.pasteAreaFrame {
                lines.append(String(format: "Paste x=%.1f y=%.1f w=%.1f h=%.1f", paste.minX, paste.minY, paste.width, paste.height))
            } else {
                lines.append("Paste: <none>")
            }
            if let panel = metrics.tokenPanelFrame {
                lines.append(String(format: "Panel x=%.1f y=%.1f w=%.1f h=%.1f", panel.minX, panel.minY, panel.width, panel.height))
            } else {
                lines.append("Panel: <none>")
            }
        }

        viewMetricsHUDLabel.text = lines.joined(separator: "\n")

        // Pin to top-left in *viewport* coordinates.
        // Note: UITextView is a UIScrollView; subviews live in content coordinates, so we must
        // offset by `contentOffset` to keep the HUD visually fixed while scrolling.
        let padding: CGFloat = 8
        let maxWidth = max(120, bounds.width - (padding * 2))
        let size = viewMetricsHUDLabel.sizeThatFits(CGSize(width: maxWidth, height: 200))
        viewMetricsHUDLabel.frame = CGRect(
            x: contentOffset.x + padding,
            y: contentOffset.y + padding,
            width: min(maxWidth, size.width + 12),
            height: min(200, size.height + 10)
        )
    }

    private func warmVisibleSemanticSpanLayoutIfNeeded() {
        guard semanticSpans.isEmpty == false else { return }
        guard let attributedText, attributedText.length > 0 else { return }
        guard let visibleRange = visibleUTF16Range(), visibleRange.length > 0 else { return }
        let warmLimit = 256
        var warmed = 0
        let expandedVisible = expandRange(visibleRange, by: 128)

        for span in semanticSpans {
            let sourceRange = span.range
            guard sourceRange.location != NSNotFound, sourceRange.length > 0 else { continue }
            let spanRange = displayRange(fromSourceRange: sourceRange)
            guard NSIntersectionRange(spanRange, expandedVisible).length > 0 else { continue }
            _ = baseHighlightRectsInContentCoordinates(in: spanRange)
            warmed += 1
            if warmed >= warmLimit { break }
        }
    }

    private func updateRubyDebugRects() {
        // Draw selection base highlight rects.
        // Furigana glyph bounds are drawn separately via `updateRubyDebugGlyphBounds()`.
        let path = CGMutablePath()

        if let range = selectionHighlightRange, range.location != NSNotFound, range.length > 0 {
            let rects = unionRectsByLine(baseHighlightRectsInContentCoordinates(in: range))
            for r in rects.prefix(64) {
                path.addRect(r)
            }
        }

        rubyDebugRectsLayer.frame = CGRect(origin: .zero, size: contentSize)
        rubyDebugRectsLayer.path = path.isEmpty ? nil : path
    }

    private func updateHeadwordBoundingRects() {
        guard semanticSpans.isEmpty == false else {
            headwordBoundingRectsLayer.path = nil
            headwordBoundingRectsLayer.isHidden = true
            return
        }

        let path = CGMutablePath()
        let maxSpans = min(semanticSpans.count, 256)
        for idx in 0..<maxSpans {
            let span = semanticSpans[idx]
            guard span.range.location != NSNotFound, span.range.length > 0 else { continue }
            let displaySpanRange = displayRange(fromSourceRange: span.range)
            // Hard-boundary spans (punctuation/whitespace) are part of the pipeline as
            // segmentation delimiters, but are not “headwords” and should not produce
            // debug bounding boxes.
            guard isHardBoundaryOnly(range: displaySpanRange) == false else { continue }
            let rects = unionRectsByLine(baseHighlightRectsInContentCoordinates(in: displaySpanRange))
            for rect in rects.prefix(4) {
                let r = rect.insetBy(dx: 0.5, dy: 0.5)
                guard r.width > 0, r.height > 0 else { continue }
                path.addRect(r)
            }
        }

        headwordBoundingRectsLayer.frame = CGRect(origin: .zero, size: contentSize)
        headwordBoundingRectsLayer.path = path.isEmpty ? nil : path
        headwordBoundingRectsLayer.isHidden = path.isEmpty
    }

    private func updateHeadwordDebugRects() {
        guard headwordDebugRectsEnabled else {
            resetHeadwordDebugLayers()
            return
        }
        installHeadwordDebugContainerIfNeeded()

        guard semanticSpans.isEmpty == false else {
            resetHeadwordDebugLayers()
            return
        }

        var pathsByKey: [DebugColorKey: CGMutablePath] = [:]
        var colorsByKey: [DebugColorKey: UIColor] = [:]
        let maxSpans = min(semanticSpans.count, 256)
        for idx in 0..<maxSpans {
            let span = semanticSpans[idx]
            guard span.range.location != NSNotFound, span.range.length > 0 else { continue }
            let displaySpanRange = displayRange(fromSourceRange: span.range)
            guard isHardBoundaryOnly(range: displaySpanRange) == false else { continue }
            guard let color = sanitizedStrokeColor(from: resolvedColorForSemanticSpan(span)) else { continue }
            let key = DebugColorKey(color: color)
            let path = pathsByKey[key] ?? CGMutablePath()
            let rects = unionRectsByLine(baseHighlightRectsInContentCoordinates(in: displaySpanRange))
            for rect in rects.prefix(4) {
                let r = rect.insetBy(dx: 0.5, dy: 0.5)
                guard r.width > 0, r.height > 0 else { continue }
                path.addRect(r)
            }
            pathsByKey[key] = path
            colorsByKey[key] = color
        }

        let frame = CGRect(origin: .zero, size: contentSize)
        applyDebugPaths(
            pathsByKey,
            colorsByKey: colorsByKey,
            storage: &headwordDebugRectLayers,
            container: headwordDebugRectsContainerLayer,
            frame: frame,
            zPosition: 45
        )
    }

    private static let hardBoundaryOnlyCharacterSet: CharacterSet = {
        CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
    }()

    private func isHardBoundaryOnly(range: NSRange) -> Bool {
        guard let attributedText, attributedText.length > 0 else { return true }
        let doc = NSRange(location: 0, length: attributedText.length)
        let bounded = NSIntersectionRange(range, doc)
        guard bounded.location != NSNotFound, bounded.length > 0 else { return true }

        let surface = (attributedText.string as NSString).substring(with: bounded)
        if surface.isEmpty { return true }

        for scalar in surface.unicodeScalars {
            if Self.hardBoundaryOnlyCharacterSet.contains(scalar) == false {
                return false
            }
        }
        return true
    }

    private func updateRubyDebugLineBands() {
        // Draw alternating content-space bands for base text lines and the ruby headroom above them.
        // TextKit 2 layout is frequently viewport-lazy; compute VISIBLE lines in view coords and
        // translate to content coords so the bands keep up with scrolling.
        // Labels (L#/R#) are useful during development but add visual noise; keep the code
        // available but default to off.
        let showLineBandLabels = UserDefaults.standard.bool(forKey: "RubyDebug.showLineBandLabels")
        // NOTE: Historically we computed visible lines in view coordinates and then added
        // `contentOffset` to translate back to content coordinates. That works when the helper
        // truly returns view-space rects, but can appear visually offset if any upstream rects
        // are already content-space. Prefer computing content-space line rects directly.
        let lines = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: true)
        let allDocumentLines = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: false)

        rubyDebugLineBandsContainerLayer.frame = CGRect(origin: .zero, size: contentSize)
        baseLineEvenLayer.frame = rubyDebugLineBandsContainerLayer.bounds
        baseLineOddLayer.frame = rubyDebugLineBandsContainerLayer.bounds
        rubyBandEvenLayer.frame = rubyDebugLineBandsContainerLayer.bounds
        rubyBandOddLayer.frame = rubyDebugLineBandsContainerLayer.bounds
        rubyDebugLineBandsLabelsLayer.frame = rubyDebugLineBandsContainerLayer.bounds

        guard lines.isEmpty == false else {
            baseLineEvenLayer.path = nil
            baseLineOddLayer.path = nil
            rubyBandEvenLayer.path = nil
            rubyBandOddLayer.path = nil
            rubyDebugLineBandsLabelsLayer.sublayers = nil
            return
        }

        let baseEven = CGMutablePath()
        let baseOdd = CGMutablePath()
        let rubyEven = CGMutablePath()
        let rubyOdd = CGMutablePath()
        let headroom = max(0, rubyHighlightHeadroom)
        let rubyBandHeight = max(0, headroom - rubyBaselineGap)
        let drawBaseBands = headwordLineBandsEnabled
        let rubyOverlayFrames: [CGRect] = {
            guard rubyAnnotationVisibility == .visible,
                  let layers = rubyOverlayContainerLayer.sublayers else {
                return []
            }
            var frames: [CGRect] = []
            frames.reserveCapacity(layers.count)
            for layer in layers {
                if let textLayer = layer as? CATextLayer {
                    frames.append(textLayer.frame)
                }
            }
            return frames
        }()
        let drawRubyBands = rubyLineBandsEnabled && (rubyBandHeight > 0 || rubyOverlayFrames.isEmpty == false)

        // Replace labels each update (visible lines only, so this is cheap).
        rubyDebugLineBandsLabelsLayer.sublayers = nil
        var labelLayers: [CALayer] = []
        if showLineBandLabels {
            let estimatedLabelCount = lines.count * ((drawBaseBands ? 1 : 0) + (drawRubyBands ? 1 : 0))
            if estimatedLabelCount > 0 {
                labelLayers.reserveCapacity(min(estimatedLabelCount, 96))
            }
        }

        func resolveRubyBandRect(for line: CGRect) -> CGRect? {
            let horizontalPadding: CGFloat = 1
            let verticalTolerance: CGFloat = 1

            // When we have actual ruby overlay geometry, restrict matches to the headroom zone
            // immediately above this line. Otherwise, ruby from earlier lines can overlap
            // horizontally and be "above" this line too, which incorrectly inflates the band.
            let headroomZone: CGFloat = max(0, headroom)
            let rubyMaxYCeiling = line.minY + verticalTolerance
            let rubyMaxYFloor = line.minY - headroomZone - verticalTolerance

            if rubyOverlayFrames.isEmpty == false {
                var minTop = CGFloat.greatestFiniteMagnitude
                var maxBottom: CGFloat = -.greatestFiniteMagnitude
                var matched = false

                for frame in rubyOverlayFrames {
                    let overlap = min(line.maxX, frame.maxX) - max(line.minX, frame.minX)
                    if overlap <= 1 { continue }
                    // Must be above the base line, but not so far above that it belongs to a
                    // different (earlier) line.
                    if frame.maxY > rubyMaxYCeiling { continue }
                    if headroomZone > 0, frame.maxY < rubyMaxYFloor { continue }
                    matched = true
                    minTop = min(minTop, frame.minY)
                    maxBottom = max(maxBottom, frame.maxY)
                }

                if matched, maxBottom > minTop {
                    let rect = CGRect(
                        x: line.minX,
                        y: minTop,
                        width: line.width,
                        height: maxBottom - minTop
                    ).insetBy(dx: -horizontalPadding, dy: -0.5)
                    return rect
                }

                // Overlay geometry is available but nothing matched this line; skip drawing
                // to avoid showing misleading ruby bands.
                return nil
            }

            guard rubyBandHeight > 0 else { return nil }
            return CGRect(
                x: line.minX,
                y: line.minY - headroom,
                width: line.width,
                height: rubyBandHeight
            ).insetBy(dx: -horizontalPadding, dy: 0)
        }

        for (idx, line) in lines.enumerated() {
            // Use document-stable parity so colors don't flip as the visible window scrolls.
            let absoluteIndex = bestMatchingLineIndex(for: line, candidates: allDocumentLines) ?? idx
            let isEven = (absoluteIndex % 2 == 0)

            if drawBaseBands {
                let baseRect = line.insetBy(dx: -1, dy: -0.5)
                if isEven {
                    baseEven.addRect(baseRect)
                } else {
                    baseOdd.addRect(baseRect)
                }

                if showLineBandLabels {
                    let baseLabel = CATextLayer()
                    baseLabel.contentsScale = traitCollection.displayScale
                    baseLabel.string = "L\(absoluteIndex)"
                    baseLabel.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
                    baseLabel.fontSize = 9
                    baseLabel.alignmentMode = .left
                    baseLabel.foregroundColor = UIColor.white.withAlphaComponent(0.92).cgColor
                    baseLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
                    baseLabel.cornerRadius = 4
                    baseLabel.masksToBounds = true
                    let labelX = max(2, line.minX + 2)
                    let labelY = max(2, line.minY + 2)
                    baseLabel.frame = CGRect(x: labelX, y: labelY, width: 26, height: 14)
                    baseLabel.actions = [
                        "position": NSNull(),
                        "bounds": NSNull(),
                        "contents": NSNull(),
                        "opacity": NSNull(),
                        "hidden": NSNull()
                    ]
                    labelLayers.append(baseLabel)
                }
            }

            if drawRubyBands, let rubyRect = resolveRubyBandRect(for: line) {
                if isEven {
                    rubyEven.addRect(rubyRect)
                } else {
                    rubyOdd.addRect(rubyRect)
                }

                if showLineBandLabels {
                    let rubyLabel = CATextLayer()
                    rubyLabel.contentsScale = traitCollection.displayScale
                    rubyLabel.string = "R\(absoluteIndex)"
                    rubyLabel.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
                    rubyLabel.fontSize = 9
                    rubyLabel.alignmentMode = .left
                    rubyLabel.foregroundColor = UIColor.white.withAlphaComponent(0.92).cgColor
                    rubyLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
                    rubyLabel.cornerRadius = 4
                    rubyLabel.masksToBounds = true
                    let labelX = max(2, line.minX + 2)
                    let labelY = max(2, rubyRect.minY + 2)
                    rubyLabel.frame = CGRect(x: labelX, y: labelY, width: 26, height: 14)
                    rubyLabel.actions = [
                        "position": NSNull(),
                        "bounds": NSNull(),
                        "contents": NSNull(),
                        "opacity": NSNull(),
                        "hidden": NSNull()
                    ]
                    labelLayers.append(rubyLabel)
                }
            }
        }

        if headwordLineBandsEnabled {
            baseLineEvenLayer.path = baseEven.isEmpty ? nil : baseEven
            baseLineOddLayer.path = baseOdd.isEmpty ? nil : baseOdd
        } else {
            baseLineEvenLayer.path = nil
            baseLineOddLayer.path = nil
        }

        if rubyLineBandsEnabled {
            rubyBandEvenLayer.path = rubyEven.isEmpty ? nil : rubyEven
            rubyBandOddLayer.path = rubyOdd.isEmpty ? nil : rubyOdd
        } else {
            rubyBandEvenLayer.path = nil
            rubyBandOddLayer.path = nil
        }
        rubyDebugLineBandsLabelsLayer.sublayers = showLineBandLabels ? labelLayers : nil
    }

    private func updateRubyDebugGlyphBounds() {
        guard rubyDebugRectsEnabled else {
            resetRubyDebugGlyphLayers()
            return
        }
        installRubyDebugGlyphContainerIfNeeded()

        guard let rubyLayers = rubyOverlayContainerLayer.sublayers, rubyLayers.isEmpty == false else {
            resetRubyDebugGlyphLayers()
            return
        }

        var pathsByKey: [DebugColorKey: CGMutablePath] = [:]
        var colorsByKey: [DebugColorKey: UIColor] = [:]

        for layer in rubyLayers {
            guard let ruby = layer as? CATextLayer else { continue }
            let rect = ruby.frame
            guard rect.isNull == false, rect.isEmpty == false else { continue }
            let rawColor = ruby.foregroundColor.map { UIColor(cgColor: $0) }
            guard let color = sanitizedStrokeColor(from: rawColor) else { continue }
            let key = DebugColorKey(color: color)
            let path = pathsByKey[key] ?? CGMutablePath()
            path.addRect(rect.insetBy(dx: -0.5, dy: -0.5))
            pathsByKey[key] = path
            colorsByKey[key] = color
        }

        let frame = CGRect(origin: .zero, size: contentSize)
        applyDebugPaths(
            pathsByKey,
            colorsByKey: colorsByKey,
            storage: &rubyDebugGlyphLayers,
            container: rubyDebugGlyphBoundsContainerLayer,
            frame: frame,
            zPosition: 60
        )
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
    }

    private func layoutRubyOverlayIfNeeded() {
        // Strategy 1: ruby is rendered via persistent overlay layers and updated only during layout.
        let signature: Int = {
            var hasher = Hasher()
            hasher.combine(bounds.width.bitPattern)
            hasher.combine(bounds.height.bitPattern)
            hasher.combine(contentSize.width.bitPattern)
            hasher.combine(contentSize.height.bitPattern)
            hasher.combine(textContainerInset.top.bitPattern)
            hasher.combine(textContainerInset.left.bitPattern)
            hasher.combine(rubyHighlightHeadroom.bitPattern)
            hasher.combine(rubyAnnotationVisibility == .visible)
            hasher.combine(cachedRubyRuns.count)
            return hasher.finalize()
        }()

        // Content-space overlays:
        // - Anchor geometry may be computed in content coordinates.
        // - Overlay layer frames must be expressed in CONTENT coordinates.
        // - Do not subtract/apply `contentOffset` when positioning layers.
        // UIKit scrolling (UITextView/UIScrollView bounds.origin) moves these layers automatically.
        rubyOverlayContainerLayer.frame = CGRect(origin: .zero, size: contentSize)

        guard rubyAnnotationVisibility == .visible else {
            rubyOverlayContainerLayer.isHidden = true
            if rubyOverlayContainerLayer.sublayers?.isEmpty == false {
                rubyOverlayContainerLayer.sublayers = nil
            }
            rubyOverlayDirty = false
            lastRubyOverlayLayoutSignature = signature
            return
        }

        rubyOverlayContainerLayer.isHidden = false

        // Fast path: nothing relevant changed.
        if rubyOverlayDirty == false && lastRubyOverlayLayoutSignature == signature {
            return
        }

        guard cachedRubyRuns.isEmpty == false else {
            rubyOverlayContainerLayer.sublayers = nil
            rubyOverlayDirty = false
            lastRubyOverlayLayoutSignature = signature
            return
        }

        let headroom = max(0, rubyHighlightHeadroom)
        guard headroom > 0 else {
            rubyOverlayContainerLayer.sublayers = nil
            rubyOverlayDirty = false
            lastRubyOverlayLayoutSignature = signature
            return
        }

        // Ensure TextKit 2 has laid out the whole document so segment rects are stable.
        layoutIfNeeded()
        if let tlm = textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Content-space anchors for content-space overlays (no contentOffset involvement).
        let lineRectsInContent = textKit2LineTypographicRectsInContentCoordinates()

        var layers: [CALayer] = []
        layers.reserveCapacity(min(2048, cachedRubyRuns.count * 2))

        for run in cachedRubyRuns {
            let baseRectsInContent = textKit2AnchorRectsInContentCoordinates(for: run.range, lineRectsInContent: lineRectsInContent)
            guard baseRectsInContent.isEmpty == false else { continue }

            let unionsInContent = unionRectsByLine(baseRectsInContent)
            guard unionsInContent.isEmpty == false else { continue }

            // If a ruby-bearing range is split across multiple visual lines (soft wrap),
            // drawing the full reading on each line looks like duplicated furigana.
            // Prefer drawing ONCE, anchored to the line containing the start of the run.
            // (Rotating the device often removes the wrap; this keeps the non-rotated case sane.)
            let preferredUnionInContent: CGRect = {
                guard unionsInContent.count > 1, let attributedText else {
                    return unionsInContent[0]
                }

                let ns = attributedText.string as NSString
                guard ns.length > 0, run.range.location >= 0, run.range.location < ns.length else {
                    return unionsInContent[0]
                }

                let firstComposed = ns.rangeOfComposedCharacterSequence(at: run.range.location)
                if firstComposed.location != NSNotFound,
                   firstComposed.length > 0,
                   NSMaxRange(firstComposed) <= ns.length {
                    let firstRects = textKit2AnchorRectsInContentCoordinates(for: firstComposed, lineRectsInContent: lineRectsInContent)
                    if let firstRect = firstRects.first,
                       let preferredLineIndex = bestMatchingLineIndex(for: firstRect, candidates: lineRectsInContent) {
                        for union in unionsInContent {
                            if let unionLineIndex = bestMatchingLineIndex(for: union, candidates: lineRectsInContent),
                               unionLineIndex == preferredLineIndex {
                                return union
                            }
                        }
                    }
                }

                return unionsInContent[0]
            }()

            let rubyPointSize = max(1.0, run.fontSize)
            let rubyFont = (self.font ?? UIFont.systemFont(ofSize: rubyPointSize)).withSize(rubyPointSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: rubyFont,
                .foregroundColor: run.color
            ]
            let size = (run.reading as NSString).size(withAttributes: attrs)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { continue }

            let baseUnionInContent = preferredUnionInContent
            let gap = max(1.0, self.rubyBaselineGap)
            // Center ruby over the base glyph bounds.
            // (If we shift ruby to eliminate left overhang, the extra width appears only on the right.)
            let xUnclamped: CGFloat = {
                if let xr = caretXRangeInContentCoordinates(for: run.range) {
                    switch rubyHorizontalAlignment {
                    case .leading:
                        return xr.startX
                    case .center:
                        let baseWidth = max(0, xr.endX - xr.startX)
                        return xr.startX + ((baseWidth - size.width) / 2.0)
                    }
                }
                switch rubyHorizontalAlignment {
                case .leading:
                    return baseUnionInContent.minX
                case .center:
                    return baseUnionInContent.midX - (size.width / 2.0)
                }
            }()

            // When headword padding is enabled, avoid left overhang at the beginning of a visual line.
            // This is the case that reads as “ruby jutting into the margin”.
            let x: CGFloat = {
                guard padHeadwordSpacing else { return xUnclamped }

                // Only clamp when this token starts a visual line.
                guard let line = bestMatchingLineRect(for: baseUnionInContent, candidates: lineRectsInContent) else {
                    return xUnclamped
                }
                let isAtLineStart = baseUnionInContent.minX <= (line.minX + 1.0)
                guard isAtLineStart else { return xUnclamped }

                // Clamp ruby so it never starts left of the headword's rendered base.
                return max(xUnclamped, baseUnionInContent.minX)
            }()
            // Place ruby in the reserved headroom above the base glyph bounds.
            // This avoids the ruby being occluded by the text layer when overlays are below it.
            let y = (baseUnionInContent.minY - gap) - size.height

            let textLayer = CATextLayer()
            textLayer.contentsScale = traitCollection.displayScale
            textLayer.string = run.reading
            textLayer.foregroundColor = run.color.cgColor
            textLayer.alignmentMode = .center
            textLayer.isWrapped = false
            textLayer.font = rubyFont
            textLayer.fontSize = run.fontSize
            // Tag the layer for hit-testing and highlight binding.
            // Ruby layers are keyed by token/span identity, not source NSRange; range-based
            // filtering can return no ruby rects depending on the active source↔display mapping.
            textLayer.setValue(run.range.location, forKey: "rubyRangeLocation")
            textLayer.setValue(run.range.length, forKey: "rubyRangeLength")
            let sourceLoc = sourceIndex(fromDisplayIndex: run.range.location)
            if let (tokenIndex, span) = semanticSpans.spanContext(containingUTF16Index: sourceLoc) {
                textLayer.setValue(tokenIndex, forKey: "rubyTokenIndex")
                textLayer.setValue(span.range.location, forKey: "rubySpanLocation")
                textLayer.setValue(span.range.length, forKey: "rubySpanLength")
            }
            textLayer.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            textLayer.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "sublayers": NSNull(),
                "contents": NSNull(),
                "opacity": NSNull(),
                "hidden": NSNull()
            ]
            layers.append(textLayer)
        }

        rubyOverlayContainerLayer.sublayers = layers
        rubyOverlayDirty = false
        lastRubyOverlayLayoutSignature = signature
    }

    private func textKit2AnchorRectsInContentCoordinates(for characterRange: NSRange, lineRectsInContent: [CGRect]) -> [CGRect] {
        if #available(iOS 15.0, *) {
            let rects = textKit2SegmentRectsInContentCoordinates(for: characterRange)
            if rects.isEmpty == false {
                // Clamp each segment to the best typographic line rect (tight vertical bounds).
                if lineRectsInContent.isEmpty == false {
                    return rects.map { seg in
                        guard let bestLine = bestMatchingLineRect(for: seg, candidates: lineRectsInContent) else { return seg }
                        var r = seg
                        r.origin.y = bestLine.minY
                        r.size.height = bestLine.height
                        return r
                    }
                }
                return rects
            }
        }

        // Fallback path: selection rects are view-coordinate; avoid using them for overlays.
        return []
    }

    private func textKit2LineTypographicRectsInContentCoordinates(visibleOnly: Bool = false) -> [CGRect] {
        guard let tlm = textLayoutManager else { return [] }

        let inset = textContainerInset

        let visibleRectInContent: CGRect? = {
            guard visibleOnly else { return nil }
            // Expand a bit vertically so we still capture the correct line rect when ruby extends above.
            let extraY = max(16, rubyHighlightHeadroom + 12)
            // In a scroll view, `bounds.origin` tracks `contentOffset`, so `bounds` is already
            // expressed in content coordinates.
            return bounds.insetBy(dx: -4, dy: -extraY)
        }()

        var rects: [CGRect] = []
        tlm.ensureLayout(for: tlm.documentRange)
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                let r = line.typographicBounds
                let contentRect = CGRect(
                    x: r.origin.x + origin.x + inset.left,
                    y: r.origin.y + origin.y + inset.top,
                    width: r.size.width,
                    height: r.size.height
                )
                if contentRect.isNull == false, contentRect.isEmpty == false {
                    if let visibleRectInContent {
                        if contentRect.intersects(visibleRectInContent) == false { continue }
                    }
                    rects.append(contentRect)
                }
            }
            return true
        }
        return rects
    }

    private func drawRubyReadings() {
        guard cachedRubyRuns.isEmpty == false else { return }

        // Precompute visible line typographic bounds once per draw pass.
        let visibleLineRectsInView = textKit2LineTypographicRectsInViewCoordinates(visibleOnly: true)

        // During fast scrolling, drawing ruby for the entire document is unnecessary and expensive.
        // Restrict work to runs that intersect the visible UTF-16 range (plus a small margin).
        let visibleRange: NSRange? = visibleUTF16Range().map { expandRange($0, by: 512) }

        for run in cachedRubyRuns {
            if let visibleRange {
                let intersection = NSIntersectionRange(run.range, visibleRange)
                if intersection.length <= 0 { continue }
            }

            // Default to the proven selection-rects-based anchor path.
            // The TextKit 2 segment path can be enabled for debugging via `RUBY_TK2_ANCHORS=1`.
            let baseRects: [CGRect] = {
                if Self.useTextKit2RubyAnchorRects {
                    return textKit2AnchorRectsInViewCoordinates(for: run.range, visibleLineRectsInView: visibleLineRectsInView)
                }
                return rubyAnchorRects(in: run.range, lineRectsInView: visibleLineRectsInView)
            }()
            guard baseRects.isEmpty == false else { continue }

            let unions = unionRectsByLine(baseRects)
            guard unions.isEmpty == false else { continue }

            let rubyPointSize = max(1.0, run.fontSize)
            let rubyFont = (self.font ?? UIFont.systemFont(ofSize: rubyPointSize)).withSize(rubyPointSize)
            let baseColor = run.color
            let attrs: [NSAttributedString.Key: Any] = [
                .font: rubyFont,
                .foregroundColor: baseColor
            ]

            for baseUnion in unions {
                let headroom = max(0, rubyHighlightHeadroom)
                guard headroom > 0 else { continue }

                let rubyRect = CGRect(
                    x: baseUnion.minX,
                    y: baseUnion.minY - headroom,
                    width: baseUnion.width,
                    height: headroom
                )

                let size = (run.reading as NSString).size(withAttributes: attrs)
                let x: CGFloat = {
                    if let xr = caretXRangeInViewCoordinates(for: run.range) {
                        switch rubyHorizontalAlignment {
                        case .leading:
                            return xr.startX
                        case .center:
                            let baseWidth = max(0, xr.endX - xr.startX)
                            return xr.startX + ((baseWidth - size.width) / 2.0)
                        }
                    }
                    switch rubyHorizontalAlignment {
                    case .leading:
                        return rubyRect.minX
                    case .center:
                        return rubyRect.midX - (size.width / 2.0)
                    }
                }()

                // Bottom-anchor ruby near the headword: keep a small consistent gap and let
                // the top edge move when ruby size changes.
                let gap = max(1.0, rubyBaselineGap)
                let y = (baseUnion.minY - gap) - size.height
                (run.reading as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            }
        }
    }

    private func textKit2AnchorRectsInViewCoordinates(for characterRange: NSRange, visibleLineRectsInView: [CGRect]) -> [CGRect] {
        if #available(iOS 15.0, *) {
            let rects = textKit2SegmentRectsInViewCoordinates(for: characterRange)
            if rects.isEmpty == false {
                // Clamp each segment to the best typographic line rect (tight vertical bounds).
                if visibleLineRectsInView.isEmpty == false {
                    return rects.map { sel in
                        guard let bestLine = bestMatchingLineRect(for: sel, candidates: visibleLineRectsInView) else { return sel }
                        var r = sel
                        r.origin.y = bestLine.minY
                        r.size.height = bestLine.height
                        return r
                    }
                }
                return rects
            }
        }

        // Fallback path (older OS / API unavailable): selection rects + vertical clamp.
        return rubyAnchorRects(in: characterRange, lineRectsInView: visibleLineRectsInView)
    }

    @available(iOS 15.0, *)
    private func textKit2SegmentRectsInViewCoordinates(for characterRange: NSRange) -> [CGRect] {
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return [] }
        guard let attributedText, NSMaxRange(characterRange) <= attributedText.length else { return [] }
        guard let tlm = textLayoutManager else { return [] }

                // Convert UTF-16 indices into TextKit 2 locations.
                guard let tcm = tlm.textContentManager else { return [] }
          let startIndex = characterRange.location
          let endIndex = NSMaxRange(characterRange)
          let docStart = tlm.documentRange.location
          guard let startLocation = tcm.location(docStart, offsetBy: startIndex),
              let endLocation = tcm.location(docStart, offsetBy: endIndex) else {
            return []
        }

        guard let textRange = NSTextRange(location: startLocation, end: endLocation) else {
            return []
        }

        // Ensure layout only for this range; full-document layout can settle fragments and
        // make ruby appear to move on highlight-only updates.
        tlm.ensureLayout(for: textRange)

        let inset = textContainerInset
        let offset = contentOffset

        var rects: [CGRect] = []
        rects.reserveCapacity(8)

        // Enumerate standard (glyph) segments for this range.
        // IMPORTANT: The segment rect `r` can be fragment-local on some OS/TextKit combinations.
        // Choose between fragment-local vs already-global rects by comparing overlap with
        // the owning fragment's typographic line rects (local, stable).
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { segment, r, _, _ in
            // TextKit 2 can provide an `NSTextRange?` for this segment; use its location to
            // find the owning layout fragment so we can normalize rect coordinates.
            let frag: NSTextLayoutFragment? = {
                guard let loc = segment?.location else { return nil }
                return tlm.textLayoutFragment(for: loc)
            }()
            let fragOrigin = frag?.layoutFragmentFrame.origin ?? .zero

            let candidateWithFrag = CGRect(
                x: r.origin.x + fragOrigin.x + inset.left - offset.x,
                y: r.origin.y + fragOrigin.y + inset.top - offset.y,
                width: r.size.width,
                height: r.size.height
            )
            let candidateNoFrag = CGRect(
                x: r.origin.x + inset.left - offset.x,
                y: r.origin.y + inset.top - offset.y,
                width: r.size.width,
                height: r.size.height
            )

            func bestLineRectInView(for rect: CGRect) -> CGRect? {
                guard let frag else { return nil }
                var best: CGRect? = nil
                var bestScore: CGFloat = 0
                for line in frag.textLineFragments {
                    let lb = line.typographicBounds
                    let lineRect = CGRect(
                        x: lb.origin.x + fragOrigin.x + inset.left - offset.x,
                        y: lb.origin.y + fragOrigin.y + inset.top - offset.y,
                        width: lb.size.width,
                        height: lb.size.height
                    )
                    let inter = rect.intersection(lineRect)
                    guard inter.isNull == false, inter.isEmpty == false else { continue }
                    let score = inter.width * inter.height
                    if score > bestScore {
                        bestScore = score
                        best = lineRect
                    }
                }
                return best
            }

            func clampToBestLine(_ rect: CGRect) -> CGRect {
                guard let bestLine = bestLineRectInView(for: rect) else { return rect }
                var out = rect
                out.origin.y = bestLine.minY
                out.size.height = bestLine.height
                return out
            }

            let picked: CGRect = {
                // If we can't find a fragment, fall back to the "withFrag" candidate.
                guard frag != nil else { return candidateWithFrag }

                // Prefer the candidate that actually overlaps a line in this fragment.
                let aLine = bestLineRectInView(for: candidateWithFrag)
                let bLine = bestLineRectInView(for: candidateNoFrag)
                let aScore: CGFloat = {
                    guard let aLine else { return 0 }
                    let inter = candidateWithFrag.intersection(aLine)
                    return (inter.isNull || inter.isEmpty) ? 0 : (inter.width * inter.height)
                }()
                let bScore: CGFloat = {
                    guard let bLine else { return 0 }
                    let inter = candidateNoFrag.intersection(bLine)
                    return (inter.isNull || inter.isEmpty) ? 0 : (inter.width * inter.height)
                }()

                let chosen = (bScore > aScore) ? candidateNoFrag : candidateWithFrag
                return clampToBestLine(chosen)
            }()

            if picked.isNull == false, picked.isEmpty == false {
                rects.append(picked)
            }
            return true
        }

        return rects
    }

    @available(iOS 15.0, *)
    private func textKit2SegmentRectsInContentCoordinates(for characterRange: NSRange) -> [CGRect] {
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return [] }
        guard let attributedText, NSMaxRange(characterRange) <= attributedText.length else { return [] }
        guard let tlm = textLayoutManager else { return [] }

        // Convert UTF-16 indices into TextKit 2 locations.
        guard let tcm = tlm.textContentManager else { return [] }
        let startIndex = characterRange.location
        let endIndex = NSMaxRange(characterRange)
        let docStart = tlm.documentRange.location
        guard let startLocation = tcm.location(docStart, offsetBy: startIndex),
              let endLocation = tcm.location(docStart, offsetBy: endIndex) else {
            return []
        }
        guard let textRange = NSTextRange(location: startLocation, end: endLocation) else {
            return []
        }

        // Ensure layout only for this range; full-document layout can settle fragments and
        // make ruby appear to move on highlight-only updates.
        tlm.ensureLayout(for: textRange)

        let inset = textContainerInset

        var rects: [CGRect] = []
        rects.reserveCapacity(8)

        // Enumerate standard (glyph) segments for this range.
        // IMPORTANT: The segment rect `r` can be fragment-local on some OS/TextKit combinations.
        // Choose between fragment-local vs already-global rects by comparing overlap with
        // typographic line rects.
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { segment, r, _, _ in
            let frag: NSTextLayoutFragment? = {
                guard let loc = segment?.location else { return nil }
                return tlm.textLayoutFragment(for: loc)
            }()
            let fragOrigin = frag?.layoutFragmentFrame.origin ?? .zero

            let candidateWithFrag = CGRect(
                x: r.origin.x + fragOrigin.x + inset.left,
                y: r.origin.y + fragOrigin.y + inset.top,
                width: r.size.width,
                height: r.size.height
            )
            let candidateNoFrag = CGRect(
                x: r.origin.x + inset.left,
                y: r.origin.y + inset.top,
                width: r.size.width,
                height: r.size.height
            )

            func bestLineRectInContent(for rect: CGRect) -> CGRect? {
                guard let frag else { return nil }
                var best: CGRect? = nil
                var bestScore: CGFloat = 0
                for line in frag.textLineFragments {
                    let lb = line.typographicBounds
                    let lineRect = CGRect(
                        x: lb.origin.x + fragOrigin.x + inset.left,
                        y: lb.origin.y + fragOrigin.y + inset.top,
                        width: lb.size.width,
                        height: lb.size.height
                    )
                    let inter = rect.intersection(lineRect)
                    guard inter.isNull == false, inter.isEmpty == false else { continue }
                    let score = inter.width * inter.height
                    if score > bestScore {
                        bestScore = score
                        best = lineRect
                    }
                }
                return best
            }

            func clampToBestLine(_ rect: CGRect) -> CGRect {
                guard let bestLine = bestLineRectInContent(for: rect) else { return rect }
                var out = rect
                out.origin.y = bestLine.minY
                out.size.height = bestLine.height
                return out
            }

            let picked: CGRect = {
                guard frag != nil else { return candidateWithFrag }

                let aLine = bestLineRectInContent(for: candidateWithFrag)
                let bLine = bestLineRectInContent(for: candidateNoFrag)
                let aScore: CGFloat = {
                    guard let aLine else { return 0 }
                    let inter = candidateWithFrag.intersection(aLine)
                    return (inter.isNull || inter.isEmpty) ? 0 : (inter.width * inter.height)
                }()
                let bScore: CGFloat = {
                    guard let bLine else { return 0 }
                    let inter = candidateNoFrag.intersection(bLine)
                    return (inter.isNull || inter.isEmpty) ? 0 : (inter.width * inter.height)
                }()

                let chosen = (bScore > aScore) ? candidateNoFrag : candidateWithFrag
                return clampToBestLine(chosen)
            }()

            if picked.isNull == false, picked.isEmpty == false {
                rects.append(picked)
            }
            return true
        }

        return rects
    }

    private func visibleUTF16Range() -> NSRange? {
        guard let attributedText, attributedText.length > 0 else { return nil }
        let maxLen = attributedText.length

        // Use `closestPosition(to:)` so we don't need TextKit 1 glyph APIs.
        // IMPORTANT: `UITextView` is a `UIScrollView`, so `bounds.origin` changes with scrolling.
        // `closestPosition(to:)` expects points in the view's coordinate space (origin at 0,0),
        // not content coordinates. Using `bounds.minY/maxY` here makes the visible range unstable
        // during scroll and can cause ruby to disappear/flicker.
        let x: CGFloat = 4.0
        let topPoint = CGPoint(x: x, y: 1.0)
        let bottomY: CGFloat = max(1.0, bounds.height - 1.0)
        let bottomPoint = CGPoint(x: x, y: bottomY)

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
        rubyOverlayDirty = true
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

            // Overlays are laid out during `layoutSubviews()`. If we were temporarily snapped to
            // the top during the attributedText update, ensure we lay out overlays again after
            // restoring the intended scroll position (no scroll callbacks).
            rubyOverlayDirty = true
            setNeedsLayout()
        }
        needsHighlightUpdate = true
        setNeedsLayout()
        // Attribute-only changes (e.g. token foreground colors) may not trigger a repaint
        // if layout metrics are unchanged. Ruby drawing depends on the attributed runs, so
        // ensure we redraw whenever the attributed text changes.
        setNeedsDisplay()
        invalidateIntrinsicContentSize()
        if Self.verboseRubyLoggingEnabled {
            CustomLogger.shared.debug("applyAttributedText -> setNeedsLayout")
        }
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

            // Ruby runs can begin with an invisible width spacer (U+FFFC) when we pad headword widths.
            // If so, the spacer's clear foregroundColor would incorrectly make ruby invisible.
            // Choose the first non-spacer glyph's color within the run.
            let backing = text.string as NSString
            let upper = min(text.length, NSMaxRange(range))
            var chosenColor: UIColor? = nil
            if range.location < upper {
                var idx = range.location
                while idx < upper {
                    let r = backing.rangeOfComposedCharacterSequence(at: idx)
                    guard r.location != NSNotFound, r.length > 0 else { break }
                    guard NSMaxRange(r) <= upper else { break }
                    let s = backing.substring(with: r)
                    if s == "\u{FFFC}" {
                        idx = NSMaxRange(r)
                        continue
                    }
                    if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        idx = NSMaxRange(r)
                        continue
                    }
                    chosenColor = text.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? UIColor
                    break
                }
            }
            let color = chosenColor ?? (text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor) ?? UIColor.label
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
        textRange(for: range) != nil else {
            baseHighlightLayer.path = nil
            rubyHighlightLayer.path = nil
            return
        }

        // Base (headword) highlight uses the FULL selected span range (including okurigana).
        // We clamp vertically to the base glyph line-height so it never covers ruby space.
        // IMPORTANT: Do not rely solely on `selectionRects(for:)` here; it can be stale
        // during the first layout pass (notably when SwiftUI/UITextView scroll state is settling),
        // which produces a vertically offset highlight until the user scrolls.
        // IMPORTANT: Highlighting must not perturb ruby positioning.
        // Avoid forcing a full-document TextKit 2 layout here; geometry helpers ensure layout
        // only for the relevant selection range.

        // Option A: ruby envelope highlight.
        // Use the union of base selection rects + ruby overlay layer bounds so the
        // highlight background matches the *visual* token width (never narrower than furigana).
        let baseRectsInView = baseHighlightRects(in: range)
        let baseRectUnionInContent: CGRect = {
            var u = CGRect.null
            for r in baseRectsInView {
                u = u.isNull ? r : u.union(r)
            }
            guard u.isNull == false else { return .null }
            return u.offsetBy(dx: contentOffset.x, dy: contentOffset.y)
        }()

        let rubyRectsInContent: [CGRect] = {
            let sourceLoc = sourceIndex(fromDisplayIndex: range.location)
            guard let (tokenIndex, _) = semanticSpans.spanContext(containingUTF16Index: sourceLoc) else { return [] }
            return rubyHighlightRectsInContentCoordinates(forTokenIndex: tokenIndex)
        }()
        let rubyRectUnionInContent: CGRect = {
            var u = CGRect.null
            for r in rubyRectsInContent {
                u = u.isNull ? r : u.union(r)
            }
            return u
        }()

        var highlightRect = baseRectUnionInContent
        if rubyRectUnionInContent.isNull == false {
            highlightRect = highlightRect.isNull ? rubyRectUnionInContent : highlightRect.union(rubyRectUnionInContent)
        }

        guard highlightRect.isNull == false, highlightRect.isEmpty == false else {
            baseHighlightLayer.path = nil
            rubyHighlightLayer.path = nil
            return
        }

        // Keep highlight overlays attached to the same scrolling container as ruby overlays.
        highlightOverlayContainerLayer.frame = CGRect(origin: .zero, size: contentSize)

        let insets = selectionHighlightInsets

        if insets != .zero {
            highlightRect.origin.x += insets.left
            highlightRect.origin.y += insets.top
            highlightRect.size.width -= (insets.left + insets.right)
            highlightRect.size.height -= (insets.top + insets.bottom)
        }

        if highlightRect.width > 0, highlightRect.height > 0 {
            baseHighlightLayer.path = UIBezierPath(roundedRect: highlightRect, cornerRadius: 6).cgPath
        } else {
            baseHighlightLayer.path = nil
        }

        // Envelope highlight already includes ruby bounds.
        rubyHighlightLayer.path = nil
    }

    private func baseHighlightRectsInContentCoordinates(in characterRange: NSRange) -> [CGRect] {
        guard let attributedText else { return [] }
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return [] }
        guard NSMaxRange(characterRange) <= attributedText.length else { return [] }

        guard #available(iOS 15.0, *) else { return [] }

        // Segment rects are in TextKit 2 coordinates; convert to content coordinates.
        // NOTE: Segment rects are locally clamped to their owning fragment's typographic line.
        return textKit2SegmentRectsInContentCoordinates(for: characterRange)
    }

    private func rubyHighlightRectsInContentCoordinates(forTokenIndex tokenIndex: Int) -> [CGRect] {
        guard attributedText != nil else { return [] }
        guard rubyAnnotationVisibility == .visible else { return [] }

        // Strategy 1 binding: highlight ruby using the actual overlay layer bounds.
        // This guarantees the highlight matches the furigana text exactly.
        guard let layers = rubyOverlayContainerLayer.sublayers, layers.isEmpty == false else { return [] }

        var results: [CGRect] = []
        results.reserveCapacity(4)

        for layer in layers {
            guard let textLayer = layer as? CATextLayer else { continue }
            guard let layerTokenIndex = textLayer.value(forKey: "rubyTokenIndex") as? Int else {
                continue
            }
            if layerTokenIndex != tokenIndex { continue }

            let r = textLayer.frame
            if r.isNull == false, r.isEmpty == false {
                results.append(r)
            }
        }

        return results
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

    private func logOnScreenWidthsIfPossible(for selection: RubySpanSelection) {
        let tokenRange = displayRange(fromSourceRange: selection.highlightRange)
        guard tokenRange.location != NSNotFound, tokenRange.length > 0 else { return }

        let range: NSRange = {
            if padHeadwordSpacing, let run = cachedRubyRuns.first(where: { NSIntersectionRange($0.range, tokenRange).length > 0 }) {
                return run.range
            }
            return tokenRange
        }()

        // Base: prefer TextKit 2 segment rects so this works even when the UITextView is not selectable.
        // These rects are view-coordinate and reflect the actual laid-out advances.
        let baseRectsInView: [CGRect] = {
            if #available(iOS 15.0, *) {
                let rects = textKit2SegmentRectsInViewCoordinates(for: range)
                if rects.isEmpty == false { return rects }
            }
            return baseHighlightRects(in: range)
        }()
        let baseUnions = unionRectsByLine(baseRectsInView)
        let baseWidth = (baseUnions.map { $0.width }.max() ?? 0)
        let baseWidestLine = baseUnions.max(by: { $0.width < $1.width })
        let baseXInView = baseWidestLine?.minX ?? 0

        // Ruby: use actual overlay layer frames (content-space) converted to view-space.
        let rubyRectsInContent = rubyHighlightRectsInContentCoordinates(forTokenIndex: selection.tokenIndex)
        let offset = contentOffset
        let rubyRectsInView = rubyRectsInContent.map { $0.offsetBy(dx: -offset.x, dy: -offset.y) }
        let rubyUnions = unionRectsByLine(rubyRectsInView)
        let rubyWidth = rubyUnions.map { $0.width }.max()
        let rubyWidestLine = rubyUnions.max(by: { $0.width < $1.width })
        let rubyXInView = rubyWidestLine?.minX ?? 0

        if let rubyWidth {
            CustomLogger.shared.debug(String(format: "METRICS offX=%.2f headword(x=%.2f w=%.2f) furigana(x=%.2f w=%.2f)", offset.x, baseXInView, baseWidth, rubyXInView, rubyWidth))
        } else {
            CustomLogger.shared.debug(String(format: "METRICS offX=%.2f headword(x=%.2f w=%.2f) furigana=<none>", offset.x, baseXInView, baseWidth))
        }
    }

    func ensureHighlightedRangeVisibleIfCovered(_ characterRange: NSRange, bottomOverlayHeight: CGFloat) {
        guard bottomOverlayHeight > 0 else { return }
        guard isScrollEnabled else { return }
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return }
        guard isTracking == false, isDragging == false, isDecelerating == false else { return }

        layoutIfNeeded()

        // Use TextKit 2 segment geometry for stability. `selectionRects(for:)` can be stale
        // during early layout passes (notably when ruby/insets are changing), which can
        // cause incorrect autoscroll.
        var rects: [CGRect] = []
        if #available(iOS 15.0, *) {
            rects = textKit2SegmentRectsInViewCoordinates(for: characterRange)
        }
        if rects.isEmpty {
            rects = baseHighlightRects(in: characterRange)
        }
        guard let lowest = rects.max(by: { $0.maxY < $1.maxY }) else { return }

        // The token action panel overlays the bottom of the view.
        let visibleMaxY = (bounds.height - bottomOverlayHeight) - 8

        var target = contentOffset
        let inset = adjustedContentInset

        // A) Vertical: reveal if covered by the bottom overlay.
        if lowest.maxY > visibleMaxY {
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug(String(format: "ensureVisible covered: lowestMaxY=%.2f visibleMaxY=%.2f overlayH=%.2f offY=%.2f", lowest.maxY, visibleMaxY, bottomOverlayHeight, contentOffset.y))
            }

            let deltaY = lowest.maxY - visibleMaxY
            target.y += deltaY

            let minY = -inset.top
            let maxY = max(minY, contentSize.height - bounds.height + inset.bottom)
            target.y = min(max(target.y, minY), maxY)
        }

        // B) Horizontal: if horizontal scrolling is enabled (no-wrap), ensure the selected
        // range is actually in view. Otherwise selecting the first token can leave you
        // on a blank horizontal slice.
        if contentSize.width > (bounds.width + 2) {
            let leftmost = rects.min(by: { $0.minX < $1.minX })
            let rightmost = rects.max(by: { $0.maxX < $1.maxX })
            if let leftmost, let rightmost {
                let margin: CGFloat = 12
                let visibleMinX: CGFloat = margin
                let visibleMaxX: CGFloat = bounds.width - margin

                if leftmost.minX < visibleMinX {
                    target.x += (leftmost.minX - visibleMinX)
                } else if rightmost.maxX > visibleMaxX {
                    target.x += (rightmost.maxX - visibleMaxX)
                }

                let minX = -inset.left
                let maxX = max(minX, contentSize.width - bounds.width + inset.right)
                target.x = min(max(target.x, minX), maxX)
            }
        }

        if (target.x - contentOffset.x).magnitude > 0.5 || (target.y - contentOffset.y).magnitude > 0.5 {
            setContentOffset(target, animated: false)
        }
    }

    func ensureHighlightedRangeVisible(_ characterRange: NSRange, bottomOverlayHeight: CGFloat) {
        guard isScrollEnabled else { return }
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return }
        guard isTracking == false, isDragging == false, isDecelerating == false else { return }

        layoutIfNeeded()

        var rects: [CGRect] = []
        if #available(iOS 15.0, *) {
            rects = textKit2SegmentRectsInViewCoordinates(for: characterRange)
        }
        if rects.isEmpty {
            rects = baseHighlightRects(in: characterRange)
        }
        guard let lowest = rects.max(by: { $0.maxY < $1.maxY }) else { return }
        guard let highest = rects.min(by: { $0.minY < $1.minY }) else { return }

        let overlay = max(0, bottomOverlayHeight)
        let inset = adjustedContentInset
        let margin: CGFloat = 12
        let visibleMinY: CGFloat = margin
        let visibleMaxY: CGFloat = (bounds.height - overlay) - margin

        var target = contentOffset

        // Scroll vertically if the range is above or below the visible window.
        if highest.minY < visibleMinY {
            target.y += (highest.minY - visibleMinY)
        } else if lowest.maxY > visibleMaxY {
            target.y += (lowest.maxY - visibleMaxY)
        }

        let minY = -inset.top
        let maxY = max(minY, contentSize.height - bounds.height + inset.bottom)
        target.y = min(max(target.y, minY), maxY)

        // Horizontal handling for no-wrap.
        if contentSize.width > (bounds.width + 2) {
            let leftmost = rects.min(by: { $0.minX < $1.minX })
            let rightmost = rects.max(by: { $0.maxX < $1.maxX })
            if let leftmost, let rightmost {
                let visibleMinX: CGFloat = margin
                let visibleMaxX: CGFloat = bounds.width - margin
                if leftmost.minX < visibleMinX {
                    target.x += (leftmost.minX - visibleMinX)
                } else if rightmost.maxX > visibleMaxX {
                    target.x += (rightmost.maxX - visibleMaxX)
                }

                let minX = -inset.left
                let maxX = max(minX, contentSize.width - bounds.width + inset.right)
                target.x = min(max(target.x, minX), maxX)
            }
        }

        if (target.x - contentOffset.x).magnitude > 0.5 || (target.y - contentOffset.y).magnitude > 0.5 {
            setContentOffset(target, animated: false)
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
            // IMPORTANT: `bounds.origin` tracks `contentOffset` in a scroll view. Our computed
            // `viewRect` values below are in view coordinates (origin-zero), so the visible rect
            // must also be origin-zero.
            let viewBounds = CGRect(origin: .zero, size: bounds.size)
            return viewBounds.insetBy(dx: -4, dy: -extraY)
        }()

        var rects: [CGRect] = []
        tlm.ensureLayout(for: tlm.documentRange)
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                let r = line.typographicBounds
                let viewRect = CGRect(
                    x: r.origin.x + origin.x + inset.left - offset.x,
                    y: r.origin.y + origin.y + inset.top - offset.y,
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
            return true
        }
        return rects
    }

    private func bestMatchingLineIndex(for rect: CGRect, candidates: [CGRect]) -> Int? {
        var bestIndex: Int? = nil
        var bestScore: CGFloat = 0

        for (idx, lineRect) in candidates.enumerated() {
            let intersection = rect.intersection(lineRect)
            guard intersection.isNull == false, intersection.isEmpty == false else { continue }
            let score = intersection.width * intersection.height
            if score > bestScore {
                bestScore = score
                bestIndex = idx
            }
        }

        return bestIndex
    }

    private func bestMatchingLineRect(for rect: CGRect, candidates: [CGRect]) -> CGRect? {
        guard let idx = bestMatchingLineIndex(for: rect, candidates: candidates) else { return nil }
        return candidates[idx]
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

        func utf16Index(at point: CGPoint) -> Int? {
            guard let pos = closestPosition(to: point) else { return nil }
            let offset = self.offset(from: beginningOfDocument, to: pos)
            return max(0, min(offset, length))
        }

        func composedRange(atUTF16Index index: Int) -> NSRange? {
            guard length > 0 else { return nil }
            let clamped = max(0, min(index, length - 1))
            return backing.rangeOfComposedCharacterSequence(at: clamped)
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

            var start = min(anchorChar.location, currentChar.location)
            var end = max(NSMaxRange(anchorChar), NSMaxRange(currentChar))

            // Clamp drag-selection so it never crosses line breaks; words
            // are constrained to a single line.
            let lineBreaks = CharacterSet.newlines
            let anchorLineStart: Int = {
                var idx = anchorChar.location
                while idx > 0 {
                    let scalar = backing.character(at: idx - 1)
                    if let u = UnicodeScalar(scalar), lineBreaks.contains(u) {
                        break
                    }
                    idx -= 1
                }
                return idx
            }()
            let anchorLineEnd: Int = {
                var idx = NSMaxRange(anchorChar)
                while idx < length {
                    let scalar = backing.character(at: idx)
                    if let u = UnicodeScalar(scalar), lineBreaks.contains(u) {
                        break
                    }
                    idx += 1
                }
                return idx
            }()

            start = max(start, anchorLineStart)
            end = min(end, anchorLineEnd)

            let selected = NSRange(location: start, length: max(0, end - start))
            applyInspectionHighlight(range: selected.length > 0 ? selected : nil)

        case .ended, .cancelled, .failed:
            defer {
                dragSelectionAnchorUTF16 = nil
                dragSelectionActive = false
            }
            guard let selected = selectionHighlightRange, selected.length > 0 else { return }
            dragSelectionEndedHandler?(sourceRange(fromDisplayRange: selected))

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
        if Self.verboseRubyLoggingEnabled {
            CustomLogger.shared.debug("Inspect tap at x=\(tapPoint.x) y=\(tapPoint.y)")
        }

        // IMPORTANT:
        // In character-tap mode (incremental lookup), do not infer a character index from
        // whitespace via "closest position" heuristics. Require a direct glyph hit (or
        // ruby overlay hit) so taps on empty areas always clear.
        let rawIndex: Int?
        if characterTapHandler != nil {
            rawIndex = utf16IndexForCharacterTap(at: tapPoint)
        } else {
            rawIndex = utf16IndexForTap(at: tapPoint)
        }

        guard let rawIndex else {
            clearInspectionHighlight()
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("Inspect tap ignored: no glyph resolved")
            }
            return
        }

        guard let resolvedIndex = resolvedTextIndex(from: rawIndex) else {
            clearInspectionHighlight()
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("Inspect tap unresolved: no base character near index=\(rawIndex)")
            }
            return
        }

        let sourceResolvedIndex = sourceIndex(fromDisplayIndex: resolvedIndex)

        // Always try to log on-screen widths for the tapped token, even when the caller
        // uses character-tap mode (PasteView) and we don't apply token highlights.
        if let selection = spanSelectionContext(forUTF16Index: sourceResolvedIndex) {
            logOnScreenWidthsIfPossible(for: selection)
        }

        if let characterTapHandler {
            // In character-tap mode, do not apply token highlights; just report the UTF-16 index.
            // IMPORTANT: do not treat whitespace/line-band taps as selection.
            // Only accept the tap if it actually hit the rendered glyphs for the resolved character
            // (or its ruby overlay glyphs when furigana is visible).
            let hitRange = composedCharacterRangeInDisplayString(atUTF16Index: resolvedIndex)
            guard hitRange.location != NSNotFound,
                  hitRange.length > 0,
                  pointHitsDisplayRange(hitRange, at: tapPoint) else {
                clearInspectionHighlight()
                if Self.verboseRubyLoggingEnabled {
                    CustomLogger.shared.debug("Inspect character tap ignored: tap did not hit glyphs")
                }
                return
            }

            clearInspectionHighlight()
            characterTapHandler(sourceResolvedIndex)
            return
        }

        guard let selection = spanSelectionContext(forUTF16Index: sourceResolvedIndex) else {
            clearInspectionHighlight()
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("Inspect tap unresolved: no annotated span contains index=\(resolvedIndex)")
            }
            return
        }

        // IMPORTANT: Do not select the "nearest" token when tapping whitespace.
        // Only accept the selection if the tap actually hit the token's rendered base glyphs
        // (or its ruby overlay glyphs when furigana is visible).
        guard pointHitsSemanticSpan(selection, at: tapPoint) else {
            clearInspectionHighlight()
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("Inspect tap ignored: tap did not hit token glyphs")
            }
            return
        }

        applyInspectionHighlight(range: displayRange(fromSourceRange: selection.highlightRange))
        notifySpanSelection(selection)

        if let details = inspectionDetails(forUTF16Index: resolvedIndex) {
            let charDescription = formattedCharacterDescription(details.character)
            let rangeDescription = "[\(details.utf16Range.location)..<\(NSMaxRange(details.utf16Range))]"
            let scalarsDescription = details.scalars.joined(separator: ", ")
            let indexSummary = rawIndex == resolvedIndex ? "\(resolvedIndex)" : "\(resolvedIndex) (resolved from \(rawIndex))"

            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("Inspect tap char=\(charDescription) utf16Index=\(indexSummary) utf16Range=\(rangeDescription) scalars=[\(scalarsDescription)]")
            }
        } else {
            let highlightDescription = "[\(selection.highlightRange.location)..<\(NSMaxRange(selection.highlightRange))]"
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("Inspect tap resolved to span range \(highlightDescription) but no character details could be extracted")
            }
        }

        logSpanResolution(for: sourceResolvedIndex)
    }

    private func composedCharacterRangeInDisplayString(atUTF16Index index: Int) -> NSRange {
        guard let text = attributedText?.string, text.isEmpty == false else { return NSRange(location: NSNotFound, length: 0) }
        let ns = text as NSString
        guard index >= 0, index < ns.length else { return NSRange(location: NSNotFound, length: 0) }
        return ns.rangeOfComposedCharacterSequence(at: index)
    }

    private func pointHitsDisplayRange(_ range: NSRange, at point: CGPoint) -> Bool {
        guard range.location != NSNotFound, range.length > 0 else { return false }

        // A) Base glyph hit-test (view coordinates).
        if let uiRange = textRange(for: range) {
            let rects = selectionRects(for: uiRange)
                .map { $0.rect }
                .filter { $0.isNull == false && $0.isEmpty == false }
            if rects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) {
                return true
            }
        }

        // B) Ruby glyph hit-test (furigana overlay layers are content-space).
        guard rubyAnnotationVisibility == .visible,
              let layers = rubyOverlayContainerLayer.sublayers,
              layers.isEmpty == false else {
            return false
        }

        let offset = contentOffset
        for layer in layers {
            guard let textLayer = layer as? CATextLayer else { continue }
            guard let loc = textLayer.value(forKey: "rubyRangeLocation") as? Int,
                  let len = textLayer.value(forKey: "rubyRangeLength") as? Int else {
                continue
            }
            let runRange = NSRange(location: loc, length: len)
            if NSIntersectionRange(runRange, range).length <= 0 { continue }

            let rInView = textLayer.frame.offsetBy(dx: -offset.x, dy: -offset.y)
            if rInView.insetBy(dx: -2, dy: -2).contains(point) {
                return true
            }
        }

        return false
    }

    private func pointHitsSemanticSpan(_ selection: RubySpanSelection, at point: CGPoint) -> Bool {
        let range = displayRange(fromSourceRange: selection.highlightRange)
        guard range.location != NSNotFound, range.length > 0 else { return false }

        // A) Base glyph hit-test (view coordinates).
        // Use UITextView's selection rects which are typically tight to rendered glyphs.
        // (TextKit 2 segment rects can be broader than expected during layout settling.)
        if let uiRange = textRange(for: range) {
            let rects = selectionRects(for: uiRange)
                .map { $0.rect }
                .filter { $0.isNull == false && $0.isEmpty == false }
            if rects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(point) }) {
                return true
            }
        }

        // B) Ruby glyph hit-test (furigana overlay layers are content-space).
        guard rubyAnnotationVisibility == .visible,
              let layers = rubyOverlayContainerLayer.sublayers,
              layers.isEmpty == false else {
            return false
        }

        let offset = contentOffset
        for layer in layers {
            guard let textLayer = layer as? CATextLayer else { continue }
            guard let loc = textLayer.value(forKey: "rubyRangeLocation") as? Int,
                  let len = textLayer.value(forKey: "rubyRangeLength") as? Int else {
                continue
            }
            let runRange = NSRange(location: loc, length: len)
            if NSIntersectionRange(runRange, range).length <= 0 { continue }

            // Convert content-space overlay rect -> view-space.
            let rInView = textLayer.frame.offsetBy(dx: -offset.x, dy: -offset.y)
            if rInView.insetBy(dx: -2, dy: -2).contains(point) {
                return true
            }
        }

        return false
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
          let sourceResolvedIndex = sourceIndex(fromDisplayIndex: resolvedIndex)
          guard spanSelectionContext(forUTF16Index: sourceResolvedIndex) != nil else { return nil }

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

        if state.canSplit {
            let split = UIAction(title: "Split", image: UIImage(systemName: "scissors")) { _ in
                actionHandler(.split)
            }
            actions.append(split)
        }

        return UIMenu(title: "", children: actions)
    }

    private func utf16IndexForTap(at point: CGPoint) -> Int? {
        guard let attributedLength = attributedText?.length, attributedLength > 0 else { return nil }

        if let directRange = characterRange(at: point) {
            let offset = offset(from: beginningOfDocument, to: directRange.start)
            guard offset >= 0, offset < attributedLength else { return nil }
            return offset
        }

          // IMPORTANT: do not require the tap to be inside a base-glyph selection rect.
          // Users often tap on furigana (above the headword). Base selection rects don't cover
          // that headroom, and they can also be temporarily stale during layout settles.
          // Instead, accept taps within the visible line "band" expanded upward by ruby headroom.
          guard pointHitsVisibleLineBand(point) else { return nil }
          guard let textRange = textRangeNearPoint(point),
              let closestPosition = textRange.start as UITextPosition? else { return nil }

        let offset = offset(from: beginningOfDocument, to: closestPosition)
        guard offset >= 0, offset < attributedLength else { return nil }

        return offset
    }

    private func utf16IndexForCharacterTap(at point: CGPoint) -> Int? {
        guard let attributedLength = attributedText?.length, attributedLength > 0 else { return nil }

        // A) Strict base-glyph hit.
        if let directRange = characterRange(at: point) {
            let offset = offset(from: beginningOfDocument, to: directRange.start)
            guard offset >= 0, offset < attributedLength else { return nil }
            return offset
        }

        // B) Ruby overlay hit (tap above headword).
        guard rubyAnnotationVisibility == .visible,
              let layers = rubyOverlayContainerLayer.sublayers,
              layers.isEmpty == false else {
            return nil
        }

        // Overlay frames are in content coordinates; convert view point to content.
        let offset = contentOffset
        let pointInContent = CGPoint(x: point.x + offset.x, y: point.y + offset.y)

        for layer in layers {
            guard let textLayer = layer as? CATextLayer else { continue }
            guard let loc = textLayer.value(forKey: "rubyRangeLocation") as? Int,
                  let len = textLayer.value(forKey: "rubyRangeLength") as? Int else {
                continue
            }

            if textLayer.frame.insetBy(dx: -2, dy: -2).contains(pointInContent) {
                let clamped = max(0, min(loc, attributedLength - 1))
                // Prefer something within the annotated run when possible.
                if len > 1 {
                    return max(0, min(loc + (len / 2), attributedLength - 1))
                }
                return clamped
            }
        }

        return nil
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
        if character.isNewline { return false }
        if character.isWhitespace { return false }
        if character == "\u{FFFC}" { return false }
        return true
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

    private func pointHitsVisibleLineBand(_ point: CGPoint) -> Bool {
        // Use TextKit 2 typographic line rects (view coordinates) and expand upward
        // by the ruby headroom so taps on furigana still resolve to the correct token.
        let lines = textKit2LineTypographicRectsInViewCoordinates(visibleOnly: true)
        guard lines.isEmpty == false else { return false }

        let headroom = max(0, rubyHighlightHeadroom)
        let extraX: CGFloat = 8
        // Expand upward generously (furigana headroom), but keep the downward slop tight.
        // Taps in empty space below the text should not resolve to the final character.
        let extraYAbove: CGFloat = 10
        let extraYBelow: CGFloat = 2

        // Quick reject: below all visible lines.
        if let maxLineMaxY = lines.map({ $0.maxY }).max(), point.y > (maxLineMaxY + extraYBelow) {
            return false
        }

        for line in lines {
            let band = CGRect(
                x: line.minX - extraX,
                y: line.minY - headroom - extraYAbove,
                width: line.width + (extraX * 2),
                height: line.height + headroom + extraYAbove + extraYBelow
            )
            if band.contains(point) {
                return true
            }
        }
        return false
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
            if Self.verboseRubyLoggingEnabled {
                CustomLogger.shared.debug("Inspect tap span unresolved: no semantic span contains index=\(index)")
            }
            return
        }
        let spanRange = span.range
        let spanSurfaceDescription = span.surface.debugDescription
        let rangeDescription = "[\(spanRange.location)..<\(NSMaxRange(spanRange))]"
        if Self.verboseRubyLoggingEnabled {
            CustomLogger.shared.debug("Inspect tap span surface=\(spanSurfaceDescription) range=\(rangeDescription)")
        }
    }

}

@available(iOS 15.0, *)
extension TokenOverlayTextView: NSTextLayoutManagerDelegate {
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = RubyHeadroomLayoutFragment(textElement: textElement, range: nil)
        fragment.rubyHeadroom = max(0, rubyReservedTopMargin)
        return fragment
    }

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, shouldBreakLineByWordBefore location: NSTextLocation) -> Bool {
        guard wrapLines else { return true }

        guard let tcm = textLayoutManager.textContentManager else { return true }
        let docStart = textLayoutManager.documentRange.location
        let charIndex = tcm.offset(from: docStart, to: location)
        return shouldAllowWordBreakBeforeCharacter(at: charIndex)
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        shouldBreakLineBefore location: any NSTextLocation,
        hyphenating: Bool
    ) -> Bool {
        // This is the critical hook: when the system can't find a "word" boundary,
        // it may fall back to character-based soft breaks. Gate ALL soft breaks so
        // semantic spans (e.g. 自由) are pushed to the next line instead of splitting.
        guard wrapLines else { return true }
        guard let tcm = textLayoutManager.textContentManager else { return true }
        let docStart = textLayoutManager.documentRange.location
        let charIndex = tcm.offset(from: docStart, to: location)
        return shouldAllowWordBreakBeforeCharacter(at: charIndex)
    }
}

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

