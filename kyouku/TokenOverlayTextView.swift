import UIKit
import CoreText
import ObjectiveC

final class TokenOverlayTextView: UITextView, UIContextMenuInteractionDelegate, UIGestureRecognizerDelegate {
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
            // Semantic span changes affect ruby layer token tagging (rubyTokenIndex) and thus
            // bisector/debug deduping. Force a ruby overlay re-layout so layers are re-tagged
            // against the latest semantic spans.
            rubyOverlayDirty = true
            debugTokenListDirty = true
            // Keep debug overlays and token hit-testing in sync without requiring the
            // headword debug toggle to be active.
            setNeedsLayout()
        }
    }

    /// Debug hook used by PasteView's token list popover.
    /// Emits a newline-separated list of semantic tokens with line number + base rect coordinates.
    var debugTokenListTextHandler: ((String) -> Void)? {
        didSet {
            debugTokenListDirty = true
            setNeedsLayout()
        }
    }

    var lastDebugTokenListSignature: Int? = nil
    var debugTokenListDirty: Bool = false

    // SOURCE (unmodified) string corresponding to semantic span coordinates.
    // Display text (`attributedText`) may include ruby-width padding insertions.
    var debugSourceText: NSString? {
        didSet {
            debugTokenListDirty = true
            setNeedsLayout()
        }
    }

    var preferredWrapBreakIndices: Set<Int> = []
    var preferredWrapBreakSignature: Int = 0
    var forcedWrapBreakIndices: Set<Int> = []
    var forcedWrapBreakSignature: Int = 0

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
    var lastAppliedRenderKey: Int? = nil

    // Vertical gap between the headword and ruby text.
    var rubyBaselineGap: CGFloat = 0.5

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

    private func clampRubyXInContentCoordinates(_ x: CGFloat, width: CGFloat) -> CGFloat {
        guard x.isFinite, width.isFinite else { return x }

        // IMPORTANT:
        // Do NOT clamp ruby to the text container's left/right guides.
        // Ruby/headword alignment is enforced by padding systems; clamping ruby independently
        // will misalign readings from their base text.
        // Only clamp to keep ruby from going fully off-screen.
        let left = contentOffset.x
        let right = contentOffset.x + bounds.width
        guard left.isFinite, right.isFinite else { return x }

        let minX = left
        let maxX = max(minX, right - width)
        return min(max(x, minX), maxX)
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
    var lastMeasuredBoundsWidth: CGFloat = 0
    var lastMeasuredTextContainerWidth: CGFloat = 0

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

    // Drag-to-adjust inter-token spacing.
    // boundaryUTF16Index is in SOURCE coordinates.
    var tokenSpacingValueProvider: ((Int) -> CGFloat)? = nil {
        didSet { updateTokenSpacingGestureState() }
    }
    var tokenSpacingChangedHandler: ((Int, CGFloat, Bool) -> Void)? = nil {
        didSet { updateTokenSpacingGestureState() }
    }

    var dragSelectionBeganHandler: (() -> Void)? = nil
    var dragSelectionEndedHandler: ((NSRange) -> Void)? = nil

    lazy var inspectionTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleInspectionTap(_:)))
        recognizer.cancelsTouchesInView = false
        return recognizer
    }()

    lazy var spanContextMenuInteraction = UIContextMenuInteraction(delegate: self)

    lazy var dragSelectionRecognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleDragSelectionLongPress(_:)))
        recognizer.minimumPressDuration = 0.15
        recognizer.allowableMovement = 10
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    lazy var tokenSpacingPanRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTokenSpacingPan(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }()

    var tokenSpacingActiveBoundaryUTF16: Int? = nil
    var tokenSpacingStartValue: CGFloat = 0

    var dragSelectionAnchorUTF16: Int? = nil
    var dragSelectionActive: Bool = false

    // Base and ruby highlights are separate paths so the base highlight can remain
    // tightly clamped to the glyph line-height while the ruby highlight occupies only
    // the reserved ruby headroom above it.
    let highlightOverlayContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        return layer
    }()
    let baseHighlightLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemYellow.withAlphaComponent(0.38).cgColor
        // No outline stroke in non-debug mode.
        layer.strokeColor = UIColor.clear.cgColor
        layer.lineWidth = 0.0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    // Debug overlay: outlines the final selection highlight envelope rects
    // (after ruby+headword union, insets, and highlight outset are applied).
    let rubyEnvelopeDebugSelectionEnvelopeRectsLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemPurple.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 1.5
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.lineDashPattern = [6, 3]
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    // Debug overlay: outlines the envelope rectangles for every semantic token.
    // This mirrors the selection envelope logic (ruby+headword union) but for all tokens.
    let rubyEnvelopeDebugAllTokenEnvelopeRectsLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemPurple.withAlphaComponent(0.85).cgColor
        layer.lineWidth = 1.0
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.lineDashPattern = [3, 3]
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    // Debug overlay: circled/outlined dictionary match spans.
    private let debugDictionaryOutlineLevel1Layer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.75).cgColor
        layer.lineWidth = 1.5
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    private let debugDictionaryOutlineLevel2Layer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemYellow.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.25
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.lineDashPattern = [6, 3]
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    private let debugDictionaryOutlineLevel3PlusLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemRed.withAlphaComponent(0.9).cgColor
        layer.lineWidth = 2.75
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.lineDashPattern = [2, 2]
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    let rubyHighlightLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.systemYellow.withAlphaComponent(0.25).cgColor
        // No outline stroke in non-debug mode.
        layer.strokeColor = UIColor.clear.cgColor
        layer.lineWidth = 0.0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()

    // Temporary diagnostic: remove after ruby-envelope highlight is verified.
    let rubyEnvelopeDebugRubyRectsLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    let rubyEnvelopeDebugBaseUnionLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    let rubyEnvelopeDebugRubyUnionLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.0
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        return layer
    }()
    let rubyEnvelopeDebugFinalUnionLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.systemRed.withAlphaComponent(0.95).cgColor
        layer.lineWidth = 2.0
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

    struct RubyRun {
        let range: NSRange
        let inkRange: NSRange
        let reading: String
        let fontSize: CGFloat
        let color: UIColor
    }

    var cachedRubyRuns: [RubyRun] = []
    private var scrollRedrawScheduled: Bool = false
    private var hasDebugDictionaryCoverageAttributes: Bool = false
    private var isClampingHorizontalOffset: Bool = false

    // Strategy 1: persistent overlay layers for ruby readings.
    // These layers are positioned during layout and then scroll automatically with the UITextView.
    let rubyOverlayContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        return layer
    }()
    private var rubyOverlayDirty: Bool = true
    private var lastRubyOverlayLayoutSignature: Int = 0
    // The resolved ruby frames that were actually used to position CATextLayer(s)
    // during the most recent `layoutRubyOverlayIfNeeded()` pass.
    // Keyed by `RubyRun.inkRange.location`.
    var rubyResolvedFramesByRunStart: [Int: CGRect] = [:]

    // Increments whenever we apply new attributed text; used so multi-pass corrections
    // can converge even when only attributes (e.g. `.kern`) change.
    var attributedTextRevision: Int = 0
    private var suppressTextKit2LayoutCallbacks: Bool = false

    static let verboseRubyLoggingEnabled: Bool = {
        ProcessInfo.processInfo.environment["RUBY_TRACE"] == "1"
    }()

    private static let legacyRubyDebugHUDDefaultsKey = "rubyDebugHUD"
    private static let viewMetricsHUDDefaultsKey = "debugViewMetricsHUD"
    private static let rubyDebugRectsDefaultsKey = "rubyDebugRects"
    private static let rubyDebugBisectorsDefaultsKey = "rubyDebugBisectors"
    private static let rubyDebugShowHeadwordBisectorsDefaultsKey = "RubyDebug.showHeadwordBisectors"
    private static let rubyDebugShowRubyBisectorsDefaultsKey = "RubyDebug.showRubyBisectors"
    private static let headwordDebugRectsDefaultsKey = "rubyHeadwordDebugRects"
    private static let headwordLineBandsDefaultsKey = "rubyHeadwordLineBands"
    private static let rubyLineBandsDefaultsKey = "rubyFuriganaLineBands"
    private static let debugInsetGuidesDefaultsKey = "RubyDebug.insetGuides"
    // Legacy toggle (pre-split): controlled labels for both headword + ruby bands.
    private static let rubyDebugShowLineNumbersDefaultsKey = "RubyDebug.showLineBandLabels"
    // New per-type toggles.
    private static let rubyDebugShowHeadwordLineNumbersDefaultsKey = "RubyDebug.showHeadwordLineNumbers"
    private static let rubyDebugShowRubyLineNumbersDefaultsKey = "RubyDebug.showRubyLineNumbers"
    private static let rubyEnvelopeDebugSelectionEnvelopeRectsDefaultsKey = "RubyEnvelopeDebug.selectionEnvelopeRects"
    private static let rubyEnvelopeDebugAllTokenEnvelopeRectsDefaultsKey = "RubyEnvelopeDebug.allTokenEnvelopeRects"

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

    // In "Boundaries" debug mode, if BOTH headword + ruby are enabled, prefer showing
    // token envelopes (ruby+headword union) instead of separate boundary layers.
    private var boundariesPreferEnvelopesEnabled: Bool {
        headwordDebugRectsEnabled && rubyDebugRectsEnabled && semanticSpans.isEmpty == false
    }

    var rubyEnvelopeDebugSelectionEnvelopeRectsEnabled: Bool {
        boundariesPreferEnvelopesEnabled
            || UserDefaults.standard.bool(forKey: Self.rubyEnvelopeDebugSelectionEnvelopeRectsDefaultsKey)
    }

    var rubyEnvelopeDebugAllTokenEnvelopeRectsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.rubyEnvelopeDebugAllTokenEnvelopeRectsDefaultsKey)
    }

    var rubyDebugBisectorsEnabled: Bool {
        let defaults = UserDefaults.standard
        // Back-compat: if the new bisector toggle is unset, follow the old `rubyDebugRects`.
        if defaults.object(forKey: Self.rubyDebugBisectorsDefaultsKey) != nil {
            return defaults.bool(forKey: Self.rubyDebugBisectorsDefaultsKey)
        }
        return defaults.bool(forKey: Self.rubyDebugRectsDefaultsKey)
    }

    private var rubyDebugShowHeadwordBisectorsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.rubyDebugShowHeadwordBisectorsDefaultsKey)
    }

    private var rubyDebugShowRubyBisectorsEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.rubyDebugShowRubyBisectorsDefaultsKey)
    }

    private func boolDefaultTrue(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }
        return true
    }

    private var legacyLineBandLabelsEnabled: Bool {
        boolDefaultTrue(Self.rubyDebugShowLineNumbersDefaultsKey)
    }

    private var rubyDebugShowHeadwordLineNumbersEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.rubyDebugShowHeadwordLineNumbersDefaultsKey) != nil {
            return defaults.bool(forKey: Self.rubyDebugShowHeadwordLineNumbersDefaultsKey)
        }
        return legacyLineBandLabelsEnabled
    }

    private var rubyDebugShowRubyLineNumbersEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.rubyDebugShowRubyLineNumbersDefaultsKey) != nil {
            return defaults.bool(forKey: Self.rubyDebugShowRubyLineNumbersDefaultsKey)
        }
        return legacyLineBandLabelsEnabled
    }

    // Used by debug token list and any callers that only care about an overall “show line numbers” intent.
    var rubyDebugShowLineNumbersEnabled: Bool {
        rubyDebugShowHeadwordLineNumbersEnabled || rubyDebugShowRubyLineNumbersEnabled
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

    private var debugInsetGuidesEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.debugInsetGuidesDefaultsKey)
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
        layer.strokeColor = RubyTextConstants.debugBoundingDefaultStrokeColor.cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = RubyTextConstants.debugBoundingDashPattern
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
        // These rects exist for stability/diagnostics; keep them non-visible by default.
        layer.strokeColor = UIColor.clear.cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = RubyTextConstants.debugBoundingDashPattern
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

    private let rubyBoundingRectsLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        // These rects exist for stability/diagnostics; keep them non-visible by default.
        layer.strokeColor = UIColor.clear.cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = RubyTextConstants.debugBoundingDashPattern
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        layer.zPosition = 41
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

    private lazy var headwordDebugLeftInsetGuideLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.white.withAlphaComponent(0.28).cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = [3, 3]
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        layer.zPosition = 44
        return layer
    }()

    private lazy var headwordDebugRightInsetGuideLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.white.withAlphaComponent(0.28).cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = [3, 3]
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        layer.zPosition = 44
        return layer
    }()

    private let debugInsetGuidesContainerLayer: CALayer = {
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

    private let debugInsetGuidesLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = UIColor.white.withAlphaComponent(0.30).cgColor
        layer.lineWidth = 1.0
        layer.lineDashPattern = [4, 3]
        layer.actions = [
            "path": NSNull(),
            "position": NSNull(),
            "bounds": NSNull(),
            "opacity": NSNull(),
            "hidden": NSNull()
        ]
        layer.isHidden = true
        layer.zPosition = 6
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

    private let rubyBisectorDebugContainerLayer: CALayer = {
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

    private lazy var rubyBisectorLeftGuideLayer: CAShapeLayer = {
        let layer = makeRubyBisectorLayer(strokeColor: UIColor.white.withAlphaComponent(0.35), zPosition: 61)
        layer.lineWidth = 1.0
        layer.lineDashPattern = [3, 3]
        return layer
    }()

    private lazy var rubyBisectorRightGuideLayer: CAShapeLayer = {
        let layer = makeRubyBisectorLayer(strokeColor: UIColor.white.withAlphaComponent(0.35), zPosition: 61)
        layer.lineWidth = 1.0
        layer.lineDashPattern = [3, 3]
        return layer
    }()

    private func makeRubyBisectorLayer(strokeColor: UIColor, zPosition: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = strokeColor.cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = nil
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

    private lazy var rubyBisectorHeadwordAlignedLayer: CAShapeLayer = {
        makeRubyBisectorLayer(strokeColor: UIColor.systemYellow.withAlphaComponent(0.98), zPosition: 62)
    }()
    private lazy var rubyBisectorHeadwordMisalignedLayer: CAShapeLayer = {
        makeRubyBisectorLayer(strokeColor: UIColor.systemGreen.withAlphaComponent(0.98), zPosition: 63)
    }()
    private lazy var rubyBisectorRubyAlignedLayer: CAShapeLayer = {
        makeRubyBisectorLayer(strokeColor: UIColor.systemYellow.withAlphaComponent(0.98), zPosition: 64)
    }()
    private lazy var rubyBisectorRubyMisalignedLayer: CAShapeLayer = {
        makeRubyBisectorLayer(strokeColor: UIColor.systemGreen.withAlphaComponent(0.98), zPosition: 65)
    }()

    private func installHeadwordDebugContainerIfNeeded() {
        if headwordDebugRectsContainerLayer.superlayer == nil {
            headwordDebugRectsContainerLayer.contentsScale = traitCollection.displayScale
            headwordDebugRectsContainerLayer.zPosition = 45
            layer.addSublayer(headwordDebugRectsContainerLayer)
        }

        if headwordDebugLeftInsetGuideLayer.superlayer == nil {
            headwordDebugRectsContainerLayer.addSublayer(headwordDebugLeftInsetGuideLayer)
        }
        if headwordDebugRightInsetGuideLayer.superlayer == nil {
            headwordDebugRectsContainerLayer.addSublayer(headwordDebugRightInsetGuideLayer)
        }
    }

    private func installRubyDebugGlyphContainerIfNeeded() {
        if rubyDebugGlyphBoundsContainerLayer.superlayer == nil {
            rubyDebugGlyphBoundsContainerLayer.contentsScale = traitCollection.displayScale
            rubyDebugGlyphBoundsContainerLayer.zPosition = 60
            layer.addSublayer(rubyDebugGlyphBoundsContainerLayer)
        }
    }

    private func installRubyBisectorDebugContainerIfNeeded() {
        if rubyBisectorDebugContainerLayer.superlayer == nil {
            rubyBisectorDebugContainerLayer.contentsScale = traitCollection.displayScale
            rubyBisectorDebugContainerLayer.zPosition = 62
            layer.addSublayer(rubyBisectorDebugContainerLayer)
        }

        if rubyBisectorLeftGuideLayer.superlayer == nil {
            rubyBisectorDebugContainerLayer.addSublayer(rubyBisectorLeftGuideLayer)
        }

        if rubyBisectorRightGuideLayer.superlayer == nil {
            rubyBisectorDebugContainerLayer.addSublayer(rubyBisectorRightGuideLayer)
        }

        if rubyBisectorHeadwordAlignedLayer.superlayer == nil {
            rubyBisectorDebugContainerLayer.addSublayer(rubyBisectorHeadwordAlignedLayer)
            rubyBisectorDebugContainerLayer.addSublayer(rubyBisectorHeadwordMisalignedLayer)
            rubyBisectorDebugContainerLayer.addSublayer(rubyBisectorRubyAlignedLayer)
            rubyBisectorDebugContainerLayer.addSublayer(rubyBisectorRubyMisalignedLayer)
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
        layer.lineDashPattern = RubyTextConstants.debugBoundingDashPattern
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
        headwordDebugLeftInsetGuideLayer.path = nil
        headwordDebugLeftInsetGuideLayer.isHidden = true
        headwordDebugRightInsetGuideLayer.path = nil
        headwordDebugRightInsetGuideLayer.isHidden = true
        headwordDebugRectsContainerLayer.isHidden = true
    }

    private func resetRubyDebugGlyphLayers() {
        for (_, layer) in rubyDebugGlyphLayers {
            layer.removeFromSuperlayer()
        }
        rubyDebugGlyphLayers.removeAll()
        rubyDebugGlyphBoundsContainerLayer.isHidden = true
    }

    private func resetRubyBisectorDebugLayers() {
        rubyBisectorDebugContainerLayer.isHidden = true
        rubyBisectorLeftGuideLayer.path = nil
        rubyBisectorLeftGuideLayer.isHidden = true
        rubyBisectorRightGuideLayer.path = nil
        rubyBisectorRightGuideLayer.isHidden = true
        rubyBisectorHeadwordAlignedLayer.path = nil
        rubyBisectorHeadwordMisalignedLayer.path = nil
        rubyBisectorRubyAlignedLayer.path = nil
        rubyBisectorRubyMisalignedLayer.path = nil
        rubyBisectorHeadwordAlignedLayer.isHidden = true
        rubyBisectorHeadwordMisalignedLayer.isHidden = true
        rubyBisectorRubyAlignedLayer.isHidden = true
        rubyBisectorRubyMisalignedLayer.isHidden = true
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
            let scrollUpdateStart = CustomLogger.perfStart()
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
            if headwordLineBandsEnabled || rubyLineBandsEnabled || rubyDebugRectsEnabled || hasDebugDictionaryCoverageAttributes {
                scheduleDebugOverlaysUpdate()
            }
            warmVisibleSemanticSpanLayoutIfNeeded()
            CustomLogger.shared.perf(
                "TokenOverlayTextView.contentOffset didSet",
                elapsedMS: CustomLogger.perfElapsedMS(since: scrollUpdateStart),
                details: "offset=(\(Int(contentOffset.x.rounded())) ,\(Int(contentOffset.y.rounded()))) semantic=\(semanticSpans.count)",
                thresholdMS: 2.0,
                level: .debug
            )
        }
    }

    private func scheduleDebugOverlaysUpdate() {
        guard scrollRedrawScheduled == false else { return }
        scrollRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scrollRedrawScheduled = false

            if self.hasDebugDictionaryCoverageAttributes {
                self.updateDebugDictionaryEntryOutlinePaths()
            }
            if self.headwordLineBandsEnabled || self.rubyLineBandsEnabled {
                self.updateRubyDebugLineBands()
            }
            if self.rubyDebugRectsEnabled, self.boundariesPreferEnvelopesEnabled == false {
                self.updateRubyDebugRects()
                self.updateRubyDebugGlyphBounds()
                self.updateRubyHeadwordBisectors()
            }
        }
    }

    private func containsDebugDictionaryCoverageAttribute(in text: NSAttributedString) -> Bool {
        guard text.length > 0 else { return false }
        let full = NSRange(location: 0, length: text.length)
        var found = false
        text.enumerateAttribute(
            DebugDictionaryHighlighting.coverageLevelAttribute,
            in: full,
            options: [.longestEffectiveRangeNotRequired]
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func updateDebugBoundingStrokeAppearance() {
        let strokeColor = resolvedDebugStrokeColor(at: 0) ?? resolvedDebugBoundingStrokeColor()
        rubyDebugRectsLayer.strokeColor = strokeColor.cgColor
        rubyDebugRectsLayer.lineDashPattern = RubyTextConstants.debugBoundingDashPattern

        updateStabilityRectAppearance()

        if headwordDebugRectsEnabled, boundariesPreferEnvelopesEnabled == false {
            updateHeadwordDebugRects()
        }
        if rubyDebugRectsEnabled, boundariesPreferEnvelopesEnabled == false {
            updateRubyDebugGlyphBounds()
            updateRubyHeadwordBisectors()
        }
    }

    private func resolvedDebugBoundingStrokeColor() -> UIColor {
        if traitCollection.userInterfaceStyle == .dark && alternateTokenColorsEnabled == false {
            return RubyTextConstants.debugBoundingDarkModeStrokeColor
        }
        return RubyTextConstants.debugBoundingDefaultStrokeColor
    }

    private func updateStabilityRectAppearance() {
        // If these layers are enabled for stability, they should never be visually prominent.
        // Use fully transparent stroke/fill so light-mode doesn't show black boxes.
        let stroke = UIColor.clear
        headwordBoundingRectsLayer.strokeColor = stroke.cgColor
        rubyBoundingRectsLayer.strokeColor = stroke.cgColor
        headwordBoundingRectsLayer.fillColor = UIColor.clear.cgColor
        rubyBoundingRectsLayer.fillColor = UIColor.clear.cgColor
    }

    private func resolvedDebugStrokeColor(at index: Int) -> UIColor? {
        guard alternateTokenColorsEnabled else { return nil }
        guard index >= 0 && index < tokenColorPalette.count else { return nil }
        return TokenOverlayTextView.emphasizedDebugStrokeColor(from: tokenColorPalette[index])
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
            if textContainer.size.width < RubyTextConstants.noWrapContainerWidth {
                textContainer.size = CGSize(width: RubyTextConstants.noWrapContainerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }

    @available(iOS 15.0, *)
    private func ensureTextKit2DelegateInstalled() {
        guard let tlm = textLayoutManager else { return }
        if (tlm.delegate as AnyObject?) !== self {
            tlm.delegate = self
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
        debugDictionaryOutlineLevel1Layer.contentsScale = traitCollection.displayScale
        debugDictionaryOutlineLevel2Layer.contentsScale = traitCollection.displayScale
        debugDictionaryOutlineLevel3PlusLayer.contentsScale = traitCollection.displayScale
        baseHighlightLayer.contentsScale = traitCollection.displayScale
        rubyHighlightLayer.contentsScale = traitCollection.displayScale
        rubyEnvelopeDebugSelectionEnvelopeRectsLayer.contentsScale = traitCollection.displayScale

        // Put dictionary outlines below selection highlights.
        highlightOverlayContainerLayer.addSublayer(debugDictionaryOutlineLevel1Layer)
        highlightOverlayContainerLayer.addSublayer(debugDictionaryOutlineLevel2Layer)
        highlightOverlayContainerLayer.addSublayer(debugDictionaryOutlineLevel3PlusLayer)
        highlightOverlayContainerLayer.addSublayer(rubyHighlightLayer)
        highlightOverlayContainerLayer.addSublayer(baseHighlightLayer)

        // Optional debug overlay: outlines the final selection envelope rects.
        // Keep this above the filled highlight layer so the stroke is visible.
        highlightOverlayContainerLayer.addSublayer(rubyEnvelopeDebugSelectionEnvelopeRectsLayer)
        rubyEnvelopeDebugSelectionEnvelopeRectsLayer.isHidden = true

        // Temporary diagnostic: only install when RUBY_TRACE=1.
        if Self.verboseRubyLoggingEnabled {
            rubyEnvelopeDebugRubyRectsLayer.contentsScale = traitCollection.displayScale
            rubyEnvelopeDebugBaseUnionLayer.contentsScale = traitCollection.displayScale
            rubyEnvelopeDebugRubyUnionLayer.contentsScale = traitCollection.displayScale
            rubyEnvelopeDebugFinalUnionLayer.contentsScale = traitCollection.displayScale
            highlightOverlayContainerLayer.addSublayer(rubyEnvelopeDebugRubyRectsLayer)
            highlightOverlayContainerLayer.addSublayer(rubyEnvelopeDebugBaseUnionLayer)
            highlightOverlayContainerLayer.addSublayer(rubyEnvelopeDebugRubyUnionLayer)
            highlightOverlayContainerLayer.addSublayer(rubyEnvelopeDebugFinalUnionLayer)
        }

        layer.addSublayer(highlightOverlayContainerLayer)

        headwordBoundingRectsLayer.contentsScale = traitCollection.displayScale
        layer.addSublayer(headwordBoundingRectsLayer)

        rubyBoundingRectsLayer.contentsScale = traitCollection.displayScale
        layer.addSublayer(rubyBoundingRectsLayer)

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
            installRubyBisectorDebugContainerIfNeeded()
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
                // Settings toggles (e.g. debug line bands) frequently coincide with viewport-lazy
                // TextKit 2 reflow. Force a ruby overlay invalidation so furigana doesn't remain
                // stuck in a pre-layout coordinate space.
                self.rubyOverlayDirty = true
                self.needsHighlightUpdate = true
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
        let layoutPassStart = CustomLogger.perfStart()
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

        let warmVisibleStart = CustomLogger.perfStart()
        warmVisibleSemanticSpanLayoutIfNeeded()
        CustomLogger.shared.perf(
            "TokenOverlayTextView.warmVisibleSemanticSpanLayoutIfNeeded",
            elapsedMS: CustomLogger.perfElapsedMS(since: warmVisibleStart),
            details: "semantic=\(semanticSpans.count)",
            thresholdMS: 2.0,
            level: .debug
        )

        // NOTE: Previously we ran a soft-wrap mitigation that shifted line-start headword-padding
        // spacers to the trailing side to avoid “ruby jutting left”. Now that ruby anchoring uses
        // `RubyRun.inkRange` (visible glyph bounds), that mitigation can remove the intended left
        // padding. Keep it available for future diagnostics, but do not run it by default.

        // Ruby highlight geometry is derived from the ruby overlay layers.
        // Ensure overlays are laid out first so highlight rects can match actual ruby bounds.
        let rubyLayoutStart = CustomLogger.perfStart()
        layoutRubyOverlayIfNeeded()
        CustomLogger.shared.perf(
            "TokenOverlayTextView.layoutRubyOverlayIfNeeded",
            elapsedMS: CustomLogger.perfElapsedMS(since: rubyLayoutStart),
            details: "runs=\(cachedRubyRuns.count) dirty=\(rubyOverlayDirty)",
            thresholdMS: 2.0,
            level: .debug
        )

        // Phase 2: right-boundary fix is wrap-only.
        // If a segment overflows the right guide, force a break before that segment start.
        if #available(iOS 15.0, *) {
            recomputeForcedWrapBreakIndicesForRightOverflowIfNeeded()
        }

        // Optional (padHeadwordSpacing only): perform a viewport-only, post-layout correction
        // to keep the first ruby on each line from overhanging the fixed line-start boundary.
        if #available(iOS 15.0, *) {
            scheduleLineStartBoundaryCorrectionIfNeeded()
        }

        #if DEBUG
        if #available(iOS 15.0, *) {
            // Run debug logging once after the current layout cycle settles.
            schedulePostLayoutDebugLogsIfNeeded()
        }
        #endif

        // Token widths are expanded pre-layout (see `RubyTextProcessing.applyRubyWidthPaddingAroundRunsIfNeeded`).
        // Do not apply any post-layout, line-level padding/correction here.

        // Update debug token listing (used by PasteView's popover) after layout/ruby overlays.
        emitDebugTokenListIfNeeded()

        // Highlights are content-space overlays; keep their container sized to content.
        // This avoids stale frames when contentSize changes but selection does not.
        highlightOverlayContainerLayer.frame = CGRect(origin: .zero, size: contentSize)
        rubyEnvelopeDebugSelectionEnvelopeRectsLayer.frame = highlightOverlayContainerLayer.bounds

        // Debug overlay: draw envelope rects around every token (ruby+headword union).
        // Uses the same toggle key as the selection envelope debug setting.
        updateRubyEnvelopeDebugTokenEnvelopesIfNeeded()

        if Self.verboseRubyLoggingEnabled {
            CustomLogger.shared.debug("layoutSubviews: needsHighlightUpdate=\(needsHighlightUpdate)")
        }
        if needsHighlightUpdate {
            updateSelectionHighlightPath()
            updateDebugDictionaryEntryOutlinePaths()
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
        if rubyDebugRectsEnabled, boundariesPreferEnvelopesEnabled == false {
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

        if rubyDebugBisectorsEnabled {
            installRubyBisectorDebugContainerIfNeeded()
            updateRubyHeadwordBisectors()
        } else {
            resetRubyBisectorDebugLayers()
        }

        if headwordDebugRectsEnabled, boundariesPreferEnvelopesEnabled == false {
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

        if debugInsetGuidesEnabled {
            if debugInsetGuidesContainerLayer.superlayer == nil {
                debugInsetGuidesContainerLayer.contentsScale = traitCollection.displayScale
                debugInsetGuidesContainerLayer.zPosition = 6
                debugInsetGuidesContainerLayer.addSublayer(debugInsetGuidesLayer)
                layer.addSublayer(debugInsetGuidesContainerLayer)
            }
            updateDebugInsetGuides()
            debugInsetGuidesContainerLayer.isHidden = false
            debugInsetGuidesLayer.isHidden = false
        } else {
            debugInsetGuidesLayer.path = nil
            debugInsetGuidesContainerLayer.isHidden = true
            debugInsetGuidesLayer.isHidden = true
        }

        CustomLogger.shared.perf(
            "TokenOverlayTextView.layoutSubviews",
            elapsedMS: CustomLogger.perfElapsedMS(since: layoutPassStart),
            details: "semantic=\(semanticSpans.count) rubyRuns=\(cachedRubyRuns.count) contentH=\(Int(contentSize.height.rounded()))",
            thresholdMS: 8.0,
            level: .debug
        )

    }

    private func updateDebugInsetGuides() {
        let inset = textContainerInset
        let leftX = inset.left + textContainer.lineFragmentPadding
        let rightX = inset.left + (textContainer.size.width - textContainer.lineFragmentPadding)
        let height = max(contentSize.height, bounds.height)
        guard leftX.isFinite, rightX.isFinite, height.isFinite, height > 0 else {
            debugInsetGuidesLayer.path = nil
            return
        }

        debugInsetGuidesContainerLayer.frame = CGRect(origin: .zero, size: CGSize(width: max(contentSize.width, bounds.width), height: height))
        debugInsetGuidesLayer.frame = debugInsetGuidesContainerLayer.bounds

        let path = CGMutablePath()
        path.move(to: CGPoint(x: leftX, y: 0))
        path.addLine(to: CGPoint(x: leftX, y: height))
        path.move(to: CGPoint(x: rightX, y: 0))
        path.addLine(to: CGPoint(x: rightX, y: height))

        debugInsetGuidesLayer.path = path
    }

    #if DEBUG
    private var headwordPaddingInvariantChecksEnabled: Bool {
        // Off by default. Enable only when actively debugging headword padding.
        UserDefaults.standard.bool(forKey: "HeadwordPaddingDebug.enforceInvariants")
    }

    private enum TokenLeftOverflowAssociatedKeys {
        static var lastSignature: UInt8 = 0
        static var lastRevision: UInt8 = 0
        static var loggedKeys: UInt8 = 0
    }

    private enum TokenWordSplitAssociatedKeys {
        static var lastSignature: UInt8 = 0
        static var loggedKeys: UInt8 = 0
    }

    private enum PostLayoutDebugLogAssociatedKeys {
        static var pendingWorkItem: UInt8 = 0
    }

    private enum GapDiagnosticsAssociatedKeys {
        static var inProgress: UInt8 = 0
    }

    @available(iOS 15.0, *)
    private var lastTokenLeftOverflowLogSignature: Int {
        get { objc_getAssociatedObject(self, &TokenLeftOverflowAssociatedKeys.lastSignature) as? Int ?? 0 }
        set { objc_setAssociatedObject(self, &TokenLeftOverflowAssociatedKeys.lastSignature, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @available(iOS 15.0, *)
    private var lastTokenLeftOverflowLoggedRevision: Int {
        get { objc_getAssociatedObject(self, &TokenLeftOverflowAssociatedKeys.lastRevision) as? Int ?? -1 }
        set { objc_setAssociatedObject(self, &TokenLeftOverflowAssociatedKeys.lastRevision, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @available(iOS 15.0, *)
    private var tokenLeftOverflowLoggedKeys: NSMutableSet {
        if let s = objc_getAssociatedObject(self, &TokenLeftOverflowAssociatedKeys.loggedKeys) as? NSMutableSet {
            return s
        }
        let s = NSMutableSet()
        objc_setAssociatedObject(self, &TokenLeftOverflowAssociatedKeys.loggedKeys, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    @available(iOS 15.0, *)
    private var lastTokenWordSplitLogSignature: Int {
        get { objc_getAssociatedObject(self, &TokenWordSplitAssociatedKeys.lastSignature) as? Int ?? 0 }
        set { objc_setAssociatedObject(self, &TokenWordSplitAssociatedKeys.lastSignature, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @available(iOS 15.0, *)
    private var tokenWordSplitLoggedKeys: NSMutableSet {
        if let s = objc_getAssociatedObject(self, &TokenWordSplitAssociatedKeys.loggedKeys) as? NSMutableSet {
            return s
        }
        let s = NSMutableSet()
        objc_setAssociatedObject(self, &TokenWordSplitAssociatedKeys.loggedKeys, s, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return s
    }

    @available(iOS 15.0, *)
    private var pendingPostLayoutDebugLogWorkItem: DispatchWorkItem? {
        get { objc_getAssociatedObject(self, &PostLayoutDebugLogAssociatedKeys.pendingWorkItem) as? DispatchWorkItem }
        set { objc_setAssociatedObject(self, &PostLayoutDebugLogAssociatedKeys.pendingWorkItem, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @available(iOS 15.0, *)
    var gapDiagnosticsInProgress: Bool {
        get { objc_getAssociatedObject(self, &GapDiagnosticsAssociatedKeys.inProgress) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &GapDiagnosticsAssociatedKeys.inProgress, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @available(iOS 15.0, *)
    private func schedulePostLayoutDebugLogsIfNeeded() {
        guard gapDiagnosticsInProgress == false else { return }
        pendingPostLayoutDebugLogWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.window != nil else { return }

            self.assertHeadwordPaddingInvariantsHard()

            // Segment spacing telemetry runs in DEBUG; invariant failure checks remain opt-in.
            self.enforceHeadwordPaddingLayoutInvariantsIfNeeded()

            // Always-on in DEBUG: logs only when overflow is detected (throttled).
            self.logTokenLeftOverflowIfNeeded()

            // Always-on in DEBUG: logs when a token spans multiple lines (throttled).
            self.logTokenWordSplitAcrossLinesIfNeeded()
        }

        pendingPostLayoutDebugLogWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    @available(iOS 15.0, *)
    private func assertHeadwordPaddingInvariantsHard() {
        guard let attributedText, attributedText.length > 0 else { return }

        let s = attributedText.string as NSString
        var idx = 0
        while idx < s.length {
            if s.character(at: idx) == 0xFFFC {
                let msg = "[HeadwordPad] FAIL spacer index=\(idx)"
                CustomLogger.shared.error(msg)
                assertionFailure(msg)
                break
            }
            idx += 1
        }

        guard semanticSpans.isEmpty == false else { return }
        let lineRectsInContent = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: true)
        guard lineRectsInContent.isEmpty == false else { return }

        struct SegmentOnLine {
            let lineIndex: Int
            let startX: CGFloat
            let endX: CGFloat
            let surface: String
        }

        var segmentsByLine: [Int: [SegmentOnLine]] = [:]
        segmentsByLine.reserveCapacity(lineRectsInContent.count)

        for span in semanticSpans {
            let displayRange = self.displayRange(fromSourceRange: span.range)
            guard displayRange.location != NSNotFound, displayRange.length > 0 else { continue }

            let baseRects = baseHighlightRectsInContentCoordinates(in: displayRange)
            guard baseRects.isEmpty == false else { continue }
            let unions = unionRectsByLine(baseRects)
            guard unions.isEmpty == false else { continue }

            let envelopePad = max(0, RubyTextProcessing.headwordEnvelopePad(in: attributedText, displayRange: displayRange))
            let tokenEndIndex = NSMaxRange(displayRange)
            guard let tokenEndCaret = TokenSpacingInvariantSource.caretRectInContentCoordinates(in: self, index: tokenEndIndex, attributedLength: attributedText.length),
                  let tokenEndLine = bestMatchingLineIndex(for: tokenEndCaret, candidates: lineRectsInContent) else {
                continue
            }

            for rect in unions {
                guard let lineIndex = bestMatchingLineIndex(for: rect, candidates: lineRectsInContent) else { continue }
                let ownedPad = (lineIndex == tokenEndLine) ? envelopePad : 0
                segmentsByLine[lineIndex, default: []].append(
                    SegmentOnLine(lineIndex: lineIndex, startX: rect.minX, endX: rect.maxX + ownedPad, surface: span.surface)
                )
            }
        }

        for line in segmentsByLine.keys.sorted() {
            guard let segments = segmentsByLine[line], segments.count > 1 else { continue }
            let ordered = segments.sorted { a, b in
                if abs(a.startX - b.startX) > TokenSpacingInvariantSource.positionTieTolerance {
                    return a.startX < b.startX
                }
                return a.endX < b.endX
            }

            var previous = ordered[0]
            for current in ordered.dropFirst() {
                let gap = current.startX - previous.endX
                if gap > 0.25 {
                    let a = previous.surface.replacingOccurrences(of: "\n", with: "\\n")
                    let b = current.surface.replacingOccurrences(of: "\n", with: "\\n")
                    let msg = String(format: "[HeadwordPad] FAIL boundary=\"%@|%@\" gap=%.2f A.end=%.2f B.start=%.2f", a, b, gap, previous.endX, current.startX)
                    CustomLogger.shared.error(msg)
                    assertionFailure(msg)
                }
                previous = current
            }
        }
    }

    @available(iOS 15.0, *)
    private func logTokenLeftOverflowIfNeeded() {
        guard let attributedText, attributedText.length > 0 else { return }
        guard semanticSpans.isEmpty == false else { return }

        // Derive visible TextKit2 line fragments (range + typographic rect) so we can reliably
        // answer “which tokens start on this line?” without depending on caret geometry.
        guard let tlm = textLayoutManager else { return }

        struct VisibleLineInfo {
            let characterRange: NSRange
            let typographicRectInContent: CGRect
        }

        func visibleLineInfos() -> [VisibleLineInfo] {
            let inset = textContainerInset

            var lines: [VisibleLineInfo] = []
            lines.reserveCapacity(64)

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
                    if contentRect.isNull || contentRect.isEmpty { continue }

                    let cr = line.characterRange
                    if cr.location == NSNotFound || cr.length <= 0 { continue }
                    lines.append(.init(characterRange: cr, typographicRectInContent: contentRect))
                }
                return true
            }

            return lines.sorted { a, b in
                if abs(a.typographicRectInContent.minY - b.typographicRectInContent.minY) > TokenSpacingInvariantSource.positionTieTolerance {
                    return a.typographicRectInContent.minY < b.typographicRectInContent.minY
                }
                return a.typographicRectInContent.minX < b.typographicRectInContent.minX
            }
        }

        let visibleLines = visibleLineInfos()
        guard visibleLines.isEmpty == false else { return }

        // NOTE: Do not reset de-dupe on every attributedTextRevision.
        // Headword padding / spacer corrections can bump the revision repeatedly while converging,
        // which would cause the same violations to log again and again.
        if lastTokenLeftOverflowLoggedRevision == -1 {
            lastTokenLeftOverflowLoggedRevision = attributedTextRevision
        }

        // Throttle by spacing-calculation state (not scroll position).
        // This mirrors the correction scheduler inputs so logs fire when spacing math changes.
        var hasher = Hasher()
        hasher.combine(attributedText.length)
        hasher.combine(cachedRubyRuns.count)
        hasher.combine(Int((textContainerInset.left * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainerInset.right * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainer.size.width * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainer.lineFragmentPadding * 10).rounded(.toNearestOrEven)))
        hasher.combine(rubyIndexMap.insertionPositions.count)
        let signature = hasher.finalize()
        guard signature != lastTokenLeftOverflowLogSignature else { return }
        lastTokenLeftOverflowLogSignature = signature

        let scale = max(1.0, traitCollection.displayScale)
        let leftGuideXPoints = TokenSpacingInvariantSource.leftGuideX(in: self)
        let leftGuideXPixels = leftGuideXPoints * scale
        guard leftGuideXPixels.isFinite else { return }

        // Include the guide position in the key, since it changes with inset/padding.
        // let leftGuideKey = Int((leftGuideXPixels * 4).rounded(.toNearestOrEven))

        // Visible band (view coordinates).
        // let extraY: CGFloat = 24
        // let visibleMinY = -extraY
        // let visibleMaxY = bounds.height + extraY

        let backing = attributedText.string as NSString

        func lineIndex(containingDisplayIndex index: Int) -> Int? {
            guard index != NSNotFound else { return nil }
            for (i, line) in visibleLines.enumerated() {
                if NSLocationInRange(index, line.characterRange) {
                    return i
                }
            }
            return nil
        }

        func rubyMinXInContentForTokenLine(tokenIndex: Int, anchorBaseMidY: CGFloat) -> CGFloat? {
            guard let layers = rubyOverlayContainerLayer.sublayers, layers.isEmpty == false else { return nil }
            let tol: CGFloat = 1.0
            var best: CGFloat? = nil
            for layer in layers {
                guard let ruby = layer as? CATextLayer else { continue }
                guard let idx = ruby.value(forKey: "rubyTokenIndex") as? Int, idx == tokenIndex else { continue }

                let storedMidY: CGFloat? = {
                    if let n = ruby.value(forKey: "rubyAnchorBaseMidY") as? NSNumber {
                        return CGFloat(n.doubleValue)
                    }
                    if let d = ruby.value(forKey: "rubyAnchorBaseMidY") as? Double {
                        return CGFloat(d)
                    }
                    return nil
                }()

                guard let midY = storedMidY, abs(midY - anchorBaseMidY) <= tol else { continue }
                let r = ruby.frame
                guard r.isNull == false, r.isEmpty == false else { continue }
                best = min(best ?? r.minX, r.minX)
            }
            return best
        }

        func tokenEnvelopeMinXInViewPoints(tokenIndex: Int, baseUnionInContent: CGRect) -> CGFloat? {
            let baseMinXInContent = baseUnionInContent.minX
            let rubyMinX = rubyMinXInContentForTokenLine(tokenIndex: tokenIndex, anchorBaseMidY: baseUnionInContent.midY)
            let envelopeMinXInContent = min(baseMinXInContent, rubyMinX ?? baseMinXInContent)
            let envelopeMinXInView = envelopeMinXInContent - contentOffset.x
            return envelopeMinXInView.isFinite ? envelopeMinXInView : nil
        }

        var logged = 0
        let maxTokens = min(semanticSpans.count, 768)

        let inkTokenRecords = TokenSpacingInvariantSource.collectInkTokenRecords(
            attributedText: attributedText,
            semanticSpans: semanticSpans,
            maxTokens: maxTokens,
            displayRangeFromSource: { sourceRange in
                self.displayRange(fromSourceRange: sourceRange)
            }
        )

        // let checkedTokens = inkTokenRecords.count
        var violations = 0

        var boundaryCandidates: [TokenSpacingInvariantSource.LeftBoundaryCandidate] = []
        boundaryCandidates.reserveCapacity(128)

        for record in inkTokenRecords {
            let tokenIndex = record.tokenIndex
            let inkRange = record.inkRange

            // Base envelope: use the same rect source as the on-screen token envelopes.
            let baseRectsInContent = baseHighlightRectsInContentCoordinatesExcludingRubySpacers(in: inkRange)
            guard baseRectsInContent.isEmpty == false else { continue }
            let baseUnionsInContent = unionRectsByLine(baseRectsInContent)
            guard baseUnionsInContent.isEmpty == false else { continue }
            let snippetRange = NSRange(location: inkRange.location, length: min(8, inkRange.length))
            let snippet = backing.substring(with: snippetRange)

            for baseUnionInContent in baseUnionsInContent {
                guard let lineIndex = bestMatchingLineIndex(for: baseUnionInContent, candidates: visibleLines.map(\ .typographicRectInContent)) else { continue }

                // // Rough visible filter.
                // let yView = (baseUnionInContent.midY - contentOffset.y)
                // if yView < visibleMinY || yView > visibleMaxY { continue }

                let baseMinXInView = baseUnionInContent.minX - contentOffset.x
                let envelopeMinXInView = tokenEnvelopeMinXInViewPoints(tokenIndex: tokenIndex, baseUnionInContent: baseUnionInContent) ?? baseMinXInView

                boundaryCandidates.append(
                    .init(
                        lineIndex: lineIndex,
                        tokenIndex: tokenIndex,
                        displayStart: inkRange.location,
                        envelopeMinX: envelopeMinXInView * scale,
                        baseMinX: baseMinXInView * scale,
                        snippet: snippet
                    )
                )
            }
        }

        let lineResults = TokenSpacingInvariantSource.evaluateLeftBoundaryLines(
            candidates: boundaryCandidates,
            leftGuideX: leftGuideXPixels,
            alignedThreshold: TokenSpacingInvariantSource.alignedThreshold(in: self)
        )

        for r in lineResults {
            // let lineIndex = r.lineIndex
            // let tokenLeftXPixels = r.tokenLeftX
            // let baseLeftXPixels = r.baseLeftX
            // let deltaPixels = r.deltaX

            // // De-dupe per line + guide + quantized delta so it only re-logs when the value changes.
            // let deltaKey = Int((deltaPixels * 2.0).rounded(.toNearestOrEven))
            // let stableLineKey = (r.tokenIndex & 0x3FFFFF) ^ ((r.displayStart & 0x3FFFFF) << 1)
            // let key = stableLineKey ^ (leftGuideKey << 2) ^ (deltaKey << 3)
            // if tokenLeftOverflowLoggedKeys.contains(key) {
            //     continue
            // }
            // tokenLeftOverflowLoggedKeys.add(key)

            if TokenSpacingInvariantSource.checkEnabled(.leftBoundary), r.isDeviation {
                violations += 1
                // CustomLogger.shared.print( String( format: "[LeftInsetBoundaryDeviation] dir=%@ lineIndex=%d token=%d start=%d leftGuidePx=%.2f tokenLeftPx=%.2f baseLeftPx=%.2f deltaPx=%.2f snippet=%@", r.direction.rawValue, lineIndex, r.tokenIndex, r.displayStart, leftGuideXPixels, tokenLeftXPixels, baseLeftXPixels, deltaPixels, r.snippet ) )
            }
            logged += 1
        }

        if logged > 0 {
            // CustomLogger.shared.print(String(format: "[LeftGuideLineSummary] leftGuidePx=%.2f checked=%d lines=%d misaligned=%d", leftGuideXPixels, checkedTokens, lineResults.count, violations))
        }
    }

    @available(iOS 15.0, *)
    private func logTokenWordSplitAcrossLinesIfNeeded() {
        guard wrapLines else { return }
        guard let attributedText, attributedText.length > 0 else { return }
        guard semanticSpans.isEmpty == false else { return }

        // Throttle: avoid spamming logs on repeated layout passes at the same scroll position.
        var hasher = Hasher()
        hasher.combine(attributedTextRevision)
        hasher.combine(attributedText.length)
        hasher.combine(semanticSpans.count)
        hasher.combine(Int((contentOffset.x * 2).rounded(.toNearestOrEven)))
        hasher.combine(Int((contentOffset.y * 2).rounded(.toNearestOrEven)))
        hasher.combine(Int((bounds.width * 2).rounded(.toNearestOrEven)))
        hasher.combine(Int((bounds.height * 2).rounded(.toNearestOrEven)))
        let signature = hasher.finalize()
        guard signature != lastTokenWordSplitLogSignature else { return }
        lastTokenWordSplitLogSignature = signature

        let lineRectsInContent = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: true)
        guard lineRectsInContent.isEmpty == false else { return }

        // Visible band in content coordinates.
        let extraY = max(16, rubyHighlightHeadroom + 12)
        let visibleRectInContent = CGRect(origin: contentOffset, size: bounds.size)
            .insetBy(dx: -4, dy: -extraY)

        let backing = attributedText.string as NSString

        var logged = 0
        let maxLogsPerPass = 24
        let maxTokens = min(semanticSpans.count, 1024)
        var violations = 0

        let inkTokenRecords = TokenSpacingInvariantSource.collectInkTokenRecords(
            attributedText: attributedText,
            semanticSpans: semanticSpans,
            maxTokens: maxTokens,
            displayRangeFromSource: { sourceRange in
                self.displayRange(fromSourceRange: sourceRange)
            }
        )

        for record in inkTokenRecords {
            if logged >= maxLogsPerPass { break }

            let tokenIndex = record.tokenIndex
            let inkRange = record.inkRange

            let baseRectsInContent = baseHighlightRectsInContentCoordinatesExcludingRubySpacers(in: inkRange)
            guard baseRectsInContent.isEmpty == false else { continue }

            let unions = unionRectsByLine(baseRectsInContent)
            if unions.count <= 1 { continue }

            // Visible-only.
            var isVisible = false
            for u in unions {
                if u.intersects(visibleRectInContent) {
                    isVisible = true
                    break
                }
            }
            if isVisible == false { continue }

            // Determine which line indices are involved (best-effort).
            var lineIndices: [Int] = []
            lineIndices.reserveCapacity(unions.count)
            for u in unions {
                if let idx = bestMatchingLineIndex(for: u, candidates: lineRectsInContent) {
                    lineIndices.append(idx)
                }
            }
            let uniqueLineIndices = Array(Set(lineIndices)).sorted()
            if uniqueLineIndices.count <= 1 { continue }

            var keyHasher = Hasher()
            keyHasher.combine(attributedTextRevision)
            keyHasher.combine(tokenIndex)
            keyHasher.combine(inkRange.location)
            keyHasher.combine(inkRange.length)
            keyHasher.combine(uniqueLineIndices.count)
            for i in uniqueLineIndices.prefix(6) { keyHasher.combine(i) }
            let key = keyHasher.finalize()
            if tokenWordSplitLoggedKeys.contains(key) { continue }
            tokenWordSplitLoggedKeys.add(key)

            violations += 1
            let snippetRange = NSRange(location: inkRange.location, length: min(12, inkRange.length))
            let snippet = backing.substring(with: snippetRange)
            let linesStr = uniqueLineIndices.map(String.init).joined(separator: ",")
            CustomLogger.shared.print("[WordSplitInvariant] token=\(tokenIndex) start=\(inkRange.location) len=\(inkRange.length) lines=\(linesStr) segments=\(unions.count) text=\(snippet)")
            logged += 1
        }

        if logged > 0 {
            CustomLogger.shared.print("[WordSplitSummary] logged=\(logged) violations=\(violations)")
        }
    }

    @available(iOS 15.0, *)
    private func enforceHeadwordPaddingLayoutInvariantsIfNeeded() {
        guard let attributedText, attributedText.length > 0 else { return }
        guard semanticSpans.isEmpty == false else { return }

        let lineRectsInContent = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: true)
        guard lineRectsInContent.isEmpty == false else { return }

        let leftInsetGuideX = TokenSpacingInvariantSource.leftGuideX(in: self)
        let rightInsetGuideX = TokenSpacingInvariantSource.rightGuideX(in: self)
        let targetLeftStartX = TokenSpacingInvariantSource.leftGuideX(in: self)

        struct TokenBoundary {
            let tokenIndex: Int
            let startLineIndex: Int
            let endLineIndex: Int
            let startX: CGFloat
            let endX: CGFloat
            let envelopePad: CGFloat
            let trailingKern: CGFloat
            let displayRange: NSRange
            let sourceRange: NSRange
            let surface: String
        }
        var boundariesByTokenIndex: [Int: TokenBoundary] = [:]
        boundariesByTokenIndex.reserveCapacity(min(2048, semanticSpans.count))

        let inkTokenRecords = TokenSpacingInvariantSource.collectInkTokenRecords(
            attributedText: attributedText,
            semanticSpans: semanticSpans,
            maxTokens: semanticSpans.count,
            displayRangeFromSource: { sourceRange in
                self.displayRange(fromSourceRange: sourceRange)
            }
        )

        for record in inkTokenRecords {
            let tokenIndex = record.tokenIndex
            let segmentRange = record.displayRange
            guard segmentRange.location != NSNotFound, segmentRange.length > 0 else { continue }

            guard let startCaret = TokenSpacingInvariantSource.caretRectInContentCoordinates(in: self, index: segmentRange.location, attributedLength: attributedText.length) else { continue }
            guard let endCaret = TokenSpacingInvariantSource.caretRectInContentCoordinates(in: self, index: NSMaxRange(segmentRange), attributedLength: attributedText.length) else { continue }

            guard let startLineIndex = TokenSpacingInvariantSource.lineIndexForCaretRect(
                startCaret,
                lineRectsInContent: lineRectsInContent,
                resolveLineIndex: { probe, candidates in
                    self.bestMatchingLineIndex(for: probe, candidates: candidates)
                }
            ) else { continue }
            guard let endLineIndex = TokenSpacingInvariantSource.lineIndexForCaretRect(
                endCaret,
                lineRectsInContent: lineRectsInContent,
                resolveLineIndex: { probe, candidates in
                    self.bestMatchingLineIndex(for: probe, candidates: candidates)
                }
            ) else { continue }

            let kern = TokenSpacingInvariantSource.trailingKern(in: attributedText, inkRange: segmentRange)
            let envelopePad = max(0, RubyTextProcessing.headwordEnvelopePad(in: attributedText, displayRange: segmentRange))
            boundariesByTokenIndex[tokenIndex] = TokenBoundary(
                tokenIndex: tokenIndex,
                startLineIndex: startLineIndex,
                endLineIndex: endLineIndex,
                startX: startCaret.minX,
                endX: endCaret.minX,
                envelopePad: envelopePad,
                trailingKern: kern,
                displayRange: record.displayRange,
                sourceRange: record.sourceRange,
                surface: record.surface
            )
        }

        let overlapTol = TokenSpacingInvariantSource.overlapTolerance(in: self)
        let kernGapTol = TokenSpacingInvariantSource.kernGapTolerance(in: self)
        let leftTol = TokenSpacingInvariantSource.leftBoundaryTolerance(in: self)
        let rightTol = TokenSpacingInvariantSource.rightBoundaryTolerance(in: self)

        @inline(__always)
        func reportFailure(_ message: String) {
            // Non-fatal on purpose.
            CustomLogger.shared.debug(message)
        }

        // Group starts/ends by line so we can avoid enforcing line-start invariants on
        // continuation lines (where no token STARTS, only continues).
        var tokensStartingOnLine: [Int: [TokenBoundary]] = [:]
        var tokensEndingOnLine: [Int: [TokenBoundary]] = [:]
        tokensStartingOnLine.reserveCapacity(lineRectsInContent.count)
        tokensEndingOnLine.reserveCapacity(lineRectsInContent.count)

        for b in boundariesByTokenIndex.values {
            tokensStartingOnLine[b.startLineIndex, default: []].append(b)
            tokensEndingOnLine[b.endLineIndex, default: []].append(b)
        }

        let leftStartCandidates: [TokenSpacingInvariantSource.StartLineCandidate] = tokensStartingOnLine.flatMap { lineIndex, starts in
            starts.map { s in
                TokenSpacingInvariantSource.StartLineCandidate(
                    lineIndex: lineIndex,
                    tokenIndex: s.tokenIndex,
                    startX: s.startX
                )
            }
        }
        let leftStartResults = TokenSpacingInvariantSource.evaluateStartLinesAgainstLeftGuide(
            candidates: leftStartCandidates,
            targetLeftX: targetLeftStartX
        )
        let leftStartByLine = Dictionary(uniqueKeysWithValues: leftStartResults.map { ($0.lineIndex, $0) })

        let sortedLineIndices = tokensStartingOnLine.keys.sorted()

        func alignedSurface(_ surface: String) -> String {
            let maxWidth = 12
            let clipped: String = {
                if surface.count > maxWidth {
                    return String(surface.prefix(maxWidth - 1)) + "…"
                }
                return surface
            }()
            let padCount = max(0, maxWidth - clipped.count)
            return clipped + String(repeating: " ", count: padCount)
        }

        func alignedKind(_ kind: String) -> String {
            let width = 11
            let clipped: String = {
                if kind.count > width {
                    return String(kind.prefix(width))
                }
                return kind
            }()
            let padCount = max(0, width - clipped.count)
            return clipped + String(repeating: " ", count: padCount)
        }

        struct LineSegmentLogItem {
            let lineIndex: Int
            let minX: CGFloat
            let maxX: CGFloat
            let ownedPad: CGFloat
            let ownedMaxX: CGFloat
            let surface: String
            let displayRange: NSRange
        }

        var segmentsByLine: [Int: [LineSegmentLogItem]] = [:]
        segmentsByLine.reserveCapacity(lineRectsInContent.count)

        for (tokenIndex, span) in semanticSpans.enumerated() {
            _ = tokenIndex

            let displayRange = self.displayRange(fromSourceRange: span.range)
            guard displayRange.location != NSNotFound, displayRange.length > 0 else { continue }

            let baseRectsInContent = baseHighlightRectsInContentCoordinatesExcludingRubySpacers(in: displayRange)
            guard baseRectsInContent.isEmpty == false else { continue }
            let baseUnionsInContent = unionRectsByLine(baseRectsInContent)
            guard baseUnionsInContent.isEmpty == false else { continue }

            for unionRect in baseUnionsInContent {
                guard let lineIndex = bestMatchingLineIndex(for: unionRect, candidates: lineRectsInContent) else { continue }
                segmentsByLine[lineIndex, default: []].append(
                    LineSegmentLogItem(
                        lineIndex: lineIndex,
                        minX: unionRect.minX,
                        maxX: unionRect.maxX,
                        ownedPad: (boundariesByTokenIndex[tokenIndex]?.endLineIndex == lineIndex)
                            ? (boundariesByTokenIndex[tokenIndex]?.envelopePad ?? 0)
                            : 0,
                        ownedMaxX: unionRect.maxX + ((boundariesByTokenIndex[tokenIndex]?.endLineIndex == lineIndex)
                            ? (boundariesByTokenIndex[tokenIndex]?.envelopePad ?? 0)
                            : 0),
                        surface: span.surface,
                        displayRange: displayRange
                    )
                )
            }
        }

        let sortedSegmentLineIndices = segmentsByLine.keys.sorted()
        let showLineNumbersInSegmentLogs = rubyDebugShowLineNumbersEnabled

        var cycleHasher = Hasher()
        cycleHasher.combine(attributedTextRevision)
        cycleHasher.combine(attributedText.length)
        cycleHasher.combine(semanticSpans.count)
        cycleHasher.combine(Int((bounds.width * 2).rounded(.toNearestOrEven)))
        cycleHasher.combine(Int((bounds.height * 2).rounded(.toNearestOrEven)))
        cycleHasher.combine(Int((contentOffset.x * 2).rounded(.toNearestOrEven)))
        cycleHasher.combine(Int((contentOffset.y * 2).rounded(.toNearestOrEven)))
        cycleHasher.combine(sortedSegmentLineIndices.count)
        let cycleToken = cycleHasher.finalize()

        let diagnosticSegmentsByLine: [Int: [GapDiagnostics.SegmentItem]] = segmentsByLine.mapValues { items in
            items.map {
                GapDiagnostics.SegmentItem(
                    lineIndex: $0.lineIndex,
                    displayRange: $0.displayRange,
                    surface: $0.surface,
                    minX: $0.minX,
                    maxX: $0.ownedMaxX
                )
            }
        }

        GapDiagnostics.runAutoVerdictsIfNeeded(
            view: self,
            cycleToken: cycleToken,
            segmentsByLine: diagnosticSegmentsByLine,
            leftGuideX: leftInsetGuideX,
            rightGuideX: rightInsetGuideX,
            attributedText: attributedText
        )

        for lineIndex in sortedSegmentLineIndices {
            guard let segments = segmentsByLine[lineIndex], segments.isEmpty == false else { continue }

            let orderedForSpacing = segments.sorted { a, b in
                if abs(a.minX - b.minX) > TokenSpacingInvariantSource.positionTieTolerance {
                    return a.minX < b.minX
                }
                return a.maxX < b.maxX
            }

            var effectiveEnds = orderedForSpacing.map { $0.ownedMaxX }
            if orderedForSpacing.count > 1 {
                for i in 1..<orderedForSpacing.count {
                    let gap = orderedForSpacing[i].minX - effectiveEnds[i - 1]
                    if abs(gap) <= 0.25 {
                        effectiveEnds[i - 1] = orderedForSpacing[i].minX
                    }
                }
            }

            for (position, cur) in orderedForSpacing.enumerated() {
                let beforeSpace: CGFloat
                let beforeKind: String
                if position == 0 {
                    beforeSpace = cur.minX - leftInsetGuideX
                    beforeKind = "LEFT_GUIDE"
                } else {
                    beforeSpace = cur.minX - effectiveEnds[position - 1]
                    beforeKind = "PREV_SEG"
                }

                let afterSpace: CGFloat
                let afterKind: String
                if position == orderedForSpacing.count - 1 {
                    afterSpace = rightInsetGuideX - effectiveEnds[position]
                    afterKind = "RIGHT_GUIDE"
                } else {
                    let next = orderedForSpacing[position + 1]
                    afterSpace = next.minX - effectiveEnds[position]
                    afterKind = "NEXT_SEG"
                }

                let surfaceForLog = alignedSurface(cur.surface)
                let beforeKindForLog = alignedKind(beforeKind)
                let afterKindForLog = alignedKind(afterKind)

//                if showLineNumbersInSegmentLogs {
//                    CustomLogger.shared.print(
//                        String(
//                            format: "[SegmentSpacing] L%03d P%02d/%02d  before(%@)=%8.2f  after(%@)=%8.2f  start=%8.2f  end=%8.2f  text=%@",
//                            lineIndex,
//                            position + 1,
//                            orderedForSpacing.count,
//                            beforeKindForLog,
//                            beforeSpace,
//                            afterKindForLog,
//                            afterSpace,
//                            cur.minX,
//                            effectiveEnds[position],
//                            surfaceForLog
//                        )
//                    )
//                } else {
//                    CustomLogger.shared.print(
//                        String(
//                            format: "[SegmentSpacing] P%02d/%02d  before(%@)=%8.2f  after(%@)=%8.2f  start=%8.2f  end=%8.2f  text=%@",
//                            position + 1,
//                            orderedForSpacing.count,
//                            beforeKindForLog,
//                            beforeSpace,
//                            afterKindForLog,
//                            afterSpace,
//                            cur.minX,
//                            effectiveEnds[position],
//                            surfaceForLog
//                        )
//                    )
//                }
            }
        }

        guard headwordPaddingInvariantChecksEnabled else { return }

        for lineIndex in sortedLineIndices {
            guard let starts = tokensStartingOnLine[lineIndex] else { continue }
            guard starts.isEmpty == false else { continue }

            // A) Left boundary: enforce for the leftmost token that STARTS on this line.
            if TokenSpacingInvariantSource.checkEnabled(.leftBoundary) {
                if let leftmost = leftStartByLine[lineIndex] {
                    if abs(leftmost.deltaX) > leftTol {
                        reportFailure(String(format: "[HeadwordPadding invariant] line %d leftmost headword startX %.2f must equal leftGuide %.2f (dx=%.2f)", lineIndex, leftmost.startX, targetLeftStartX, leftmost.deltaX))
                    }
                }
            }

            // B) Right boundary: enforce for tokens that END on this line.
            if TokenSpacingInvariantSource.checkEnabled(.rightBoundary) {
                if let ends = tokensEndingOnLine[lineIndex] {
                    for r in ends {
                        let overflow = r.endX - rightInsetGuideX
                        if overflow > rightTol {
                            reportFailure(String(format: "[HeadwordPadding invariant] line %d token %d exceeds right wrap guide. endX=%.2f rightGuide=%.2f overflow=%.2f", lineIndex, r.tokenIndex, r.endX, rightInsetGuideX, overflow))
                        }
                    }
                }
            }

            // C) Gap/kern + monotonicity: enforce only for truly adjacent semantic tokens
            // whose end/start carets land on this SAME line.
            let orderedStarts = starts.sorted { a, b in
                if a.tokenIndex != b.tokenIndex { return a.tokenIndex < b.tokenIndex }
                return a.startX < b.startX
            }

            for cur in orderedStarts {
                let prevIndex = cur.tokenIndex - 1
                guard prevIndex >= 0 else { continue }
                guard let prev = boundariesByTokenIndex[prevIndex] else { continue }
                guard prev.endLineIndex == lineIndex else { continue }

                // Right boundary of previous token must include envelope-owned width.
                let prevOwnedEnd = prev.endX + prev.envelopePad
                let gap = cur.startX - prevOwnedEnd
                if TokenSpacingInvariantSource.checkEnabled(.nonOverlap), gap < -overlapTol {
                    reportFailure(String(format: "[HeadwordPadding invariant] overlap on line %d. prev=%d endX=%.2f envPad=%.2f next=%d startX=%.2f gap=%.2f", lineIndex, prev.tokenIndex, prev.endX, prev.envelopePad, cur.tokenIndex, cur.startX, gap))
                }

                let expected: CGFloat = 0
                if TokenSpacingInvariantSource.checkEnabled(.gapMatchesKern),
                   abs(gap - expected) > kernGapTol {
                    reportFailure(String(format: "[HeadwordPadding invariant] gap != 0 between consecutive headwords on line %d. prev=%d next=%d gap=%.2f prevOwnedEnd=%.2f nextStartX=%.2f", lineIndex, prev.tokenIndex, cur.tokenIndex, gap, prevOwnedEnd, cur.startX))
                }
            }
        }
    }
    #endif

    @available(iOS, deprecated: 17.0, message: "Use UITraitChangeObservable APIs once iOS 17+ only.")
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateDebugBoundingStrokeAppearance()
            updateStabilityRectAppearance()
        }
    }

    private func updateRubyBoundingRects(resolvedFramesByRunStart: [Int: CGRect]) {
        let path = CGMutablePath()

        // Bound work; ruby overlay can be large in long docs.
        var added = 0
        let maxRects = 512
        for rect in resolvedFramesByRunStart.values {
            if added >= maxRects { break }
            let r = rect.insetBy(dx: 0.5, dy: 0.5)
            guard r.width > 0, r.height > 0 else { continue }
            path.addRect(r)
            added += 1
        }

        rubyBoundingRectsLayer.frame = CGRect(origin: .zero, size: contentSize)
        rubyBoundingRectsLayer.path = path.isEmpty ? nil : path
        rubyBoundingRectsLayer.isHidden = path.isEmpty
    }

    private func updateViewMetricsHUD() {
        guard viewMetricsHUDLabel.superview != nil else { return }

        let defaults = UserDefaults.standard

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

        let showTokenPositions: Bool = {
            // When the HUD is enabled, default token listing to ON unless explicitly disabled.
            let key = "RubyDebug.hudShowTokenPositions"
            if defaults.object(forKey: key) != nil {
                return defaults.bool(forKey: key)
            }
            return true
        }()

        if showTokenPositions, semanticSpans.isEmpty == false, let attributedText {
            let inkTokenRecords = TokenSpacingInvariantSource.collectInkTokenRecords(
                attributedText: attributedText,
                semanticSpans: semanticSpans,
                maxTokens: semanticSpans.count,
                displayRangeFromSource: { sourceRange in
                    self.displayRange(fromSourceRange: sourceRange)
                },
                shouldSkipDisplayRange: { displayRange in
                    self.isHardBoundaryOnly(range: displayRange)
                }
            )

            let visible = visibleUTF16Range()
            let expandedVisible = visible.map { expandRange($0, by: 128) }
            let lineRects = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: false)

            func f1(_ v: CGFloat) -> String { String(format: "%.1f", v) }
            func formatRect(_ r: CGRect) -> String {
                "x=\(f1(r.minX)) y=\(f1(r.minY)) w=\(f1(r.width)) h=\(f1(r.height))"
            }

            let maxPrinted = 16
            var printed = 0

            for record in inkTokenRecords {
                if printed >= maxPrinted { break }

                if let expandedVisible,
                   NSIntersectionRange(record.displayRange, expandedVisible).length == 0 {
                    continue
                }

                let rects = unionRectsByLine(baseHighlightRectsInContentCoordinates(in: record.displayRange))
                guard let primary = rects.first else { continue }

                let lineIndices: [Int] = rects.compactMap { bestMatchingLineIndex(for: $0, candidates: lineRects) }
                let lineDesc: String = {
                    let unique = Array(Set(lineIndices)).sorted()
                    if unique.isEmpty { return "L?" }
                    if unique.count == 1 { return "L\(unique[0])" }
                    let joined = unique.prefix(4).map(String.init).joined(separator: ",")
                    return unique.count > 4 ? "L\(joined),…" : "L\(joined)"
                }()

                let surface = record.surface.replacingOccurrences(of: "\n", with: "\\n")
                let start = record.sourceRange.location
                let end = NSMaxRange(record.sourceRange)
                lines.append(
                    "T[\(record.tokenIndex)] r=\(start)-\(end) \(lineDesc) mid=\(f1(primary.midX)),\(f1(primary.midY)) \(formatRect(primary)) «\(surface)»"
                )
                printed += 1
            }

            let remaining = max(0, inkTokenRecords.count - printed)
            if remaining > 0 {
                lines.append("… +\(remaining) more")
            }
        }

        viewMetricsHUDLabel.text = lines.joined(separator: "\n")

        // Pin to top-left in *viewport* coordinates.
        // Note: UITextView is a UIScrollView; subviews live in content coordinates, so we must
        // offset by `contentOffset` to keep the HUD visually fixed while scrolling.
        let padding: CGFloat = 8
        let maxWidth = max(120, bounds.width - (padding * 2))
        let maxHeight: CGFloat = 420
        let size = viewMetricsHUDLabel.sizeThatFits(CGSize(width: maxWidth, height: maxHeight))
        viewMetricsHUDLabel.frame = CGRect(
            x: contentOffset.x + padding,
            y: contentOffset.y + padding,
            width: min(maxWidth, size.width + 12),
            height: min(maxHeight, size.height + 10)
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

    private func updateDebugDictionaryEntryOutlinePaths() {
        guard let attributedText, attributedText.length > 0 else {
            debugDictionaryOutlineLevel1Layer.path = nil
            debugDictionaryOutlineLevel2Layer.path = nil
            debugDictionaryOutlineLevel3PlusLayer.path = nil
            return
        }

        let doc = NSRange(location: 0, length: attributedText.length)

        // Keep debug work bounded to the viewport.
        let visible = visibleUTF16Range() ?? doc
        let scan = expandRange(visible, by: 256)

        let path1 = CGMutablePath()
        let path2 = CGMutablePath()
        let path3 = CGMutablePath()
        var added = 0
        let maxRects = 1024

        func coverageCount(from value: Any?) -> Int {
            if let n = value as? Int { return n }
            if let num = value as? NSNumber { return num.intValue }
            return 0
        }

        func addRoundedOutlineRects(for range: NSRange, ringCount: Int, to path: CGMutablePath) {
            let rects = unionRectsByLine(baseHighlightRectsInContentCoordinates(in: range))
            for rect in rects.prefix(6) {
                guard added < maxRects else { return }
                // Slightly expand so the outline doesn't touch glyph ink.
                // For overlaps, draw multiple concentric rings to make stacking obvious.
                let rings = max(1, min(3, ringCount))
                for ring in 0..<rings {
                    guard added < maxRects else { return }
                    let dx = -2.0 - (CGFloat(ring) * 1.8)
                    let dy = -1.0 - (CGFloat(ring) * 1.2)
                    let expanded = rect.insetBy(dx: dx, dy: dy)
                    guard expanded.width > 1, expanded.height > 1 else { continue }
                    let radius = min(16, max(4, expanded.height * 0.50))
                    path.addPath(UIBezierPath(roundedRect: expanded, cornerRadius: radius).cgPath)
                    added += 1
                }
            }
        }

        attributedText.enumerateAttribute(
            DebugDictionaryHighlighting.coverageLevelAttribute,
            in: NSIntersectionRange(scan, doc),
            options: []
        ) { value, range, _ in
            let c = coverageCount(from: value)
            guard c > 0 else { return }
            guard range.location != NSNotFound, range.length > 0 else { return }

            if c >= 3 {
                addRoundedOutlineRects(for: range, ringCount: 3, to: path3)
            } else if c == 2 {
                addRoundedOutlineRects(for: range, ringCount: 2, to: path2)
            } else {
                addRoundedOutlineRects(for: range, ringCount: 1, to: path1)
            }
        }

        debugDictionaryOutlineLevel1Layer.frame = CGRect(origin: .zero, size: contentSize)
        debugDictionaryOutlineLevel2Layer.frame = CGRect(origin: .zero, size: contentSize)
        debugDictionaryOutlineLevel3PlusLayer.frame = CGRect(origin: .zero, size: contentSize)

        debugDictionaryOutlineLevel1Layer.path = path1.isEmpty ? nil : path1
        debugDictionaryOutlineLevel2Layer.path = path2.isEmpty ? nil : path2
        debugDictionaryOutlineLevel3PlusLayer.path = path3.isEmpty ? nil : path3
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

        // Inset guides: left = line start boundary, right = wrap boundary.
        let guidesHeight = contentSize.height
        let leftGuideX = TokenSpacingInvariantSource.leftGuideX(in: self)
        let rightGuideX = TokenSpacingInvariantSource.rightGuideX(in: self)
        let guidesPathLeft = CGMutablePath()
        let guidesPathRight = CGMutablePath()
        if guidesHeight.isFinite, guidesHeight > 0, leftGuideX.isFinite, rightGuideX.isFinite {
            guidesPathLeft.move(to: CGPoint(x: leftGuideX, y: 0))
            guidesPathLeft.addLine(to: CGPoint(x: leftGuideX, y: guidesHeight))
            guidesPathRight.move(to: CGPoint(x: rightGuideX, y: 0))
            guidesPathRight.addLine(to: CGPoint(x: rightGuideX, y: guidesHeight))
        }

        headwordDebugLeftInsetGuideLayer.frame = headwordDebugRectsContainerLayer.bounds
        headwordDebugLeftInsetGuideLayer.path = guidesPathLeft.isEmpty ? nil : guidesPathLeft
        headwordDebugLeftInsetGuideLayer.isHidden = guidesPathLeft.isEmpty

        headwordDebugRightInsetGuideLayer.frame = headwordDebugRectsContainerLayer.bounds
        headwordDebugRightInsetGuideLayer.path = guidesPathRight.isEmpty ? nil : guidesPathRight
        headwordDebugRightInsetGuideLayer.isHidden = guidesPathRight.isEmpty

        // Ensure guides remain visible even if there are no token rect paths.
        headwordDebugRectsContainerLayer.isHidden = guidesPathLeft.isEmpty && guidesPathRight.isEmpty && pathsByKey.isEmpty
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
        // Labels (L#/R#) are useful during debugging, but should be separately toggleable.
        let showHeadwordLineBandLabels: Bool = headwordLineBandsEnabled && rubyDebugShowHeadwordLineNumbersEnabled
        let showRubyLineBandLabels: Bool = rubyLineBandsEnabled && rubyDebugShowRubyLineNumbersEnabled
        let showAnyLineBandLabels: Bool = showHeadwordLineBandLabels || showRubyLineBandLabels
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
        if showAnyLineBandLabels {
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

                if showHeadwordLineBandLabels {
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

                if showRubyLineBandLabels {
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
        rubyDebugLineBandsLabelsLayer.sublayers = showAnyLineBandLabels ? labelLayers : nil
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

    private func updateRubyHeadwordBisectors() {
        guard rubyDebugBisectorsEnabled else {
            resetRubyBisectorDebugLayers()
            return
        }
        guard let attributedText, attributedText.length > 0 else {
            resetRubyBisectorDebugLayers()
            return
        }
        guard rubyAnnotationVisibility == .visible else {
            resetRubyBisectorDebugLayers()
            return
        }
        installRubyBisectorDebugContainerIfNeeded()

        // Content-space overlay.
        rubyBisectorDebugContainerLayer.frame = CGRect(origin: .zero, size: contentSize)

        let drawHeadwordBisectors = rubyDebugShowHeadwordBisectorsEnabled
        let drawRubyBisectors = rubyDebugShowRubyBisectorsEnabled
        if drawHeadwordBisectors == false, drawRubyBisectors == false {
            resetRubyBisectorDebugLayers()
            return
        }

        guard let rubyLayers = rubyOverlayContainerLayer.sublayers, rubyLayers.isEmpty == false else {
            resetRubyBisectorDebugLayers()
            return
        }

        // Use full line rects (not visible-only) so any stored ruby anchor metadata remains stable.
        let lineRectsInContent = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: false)

        // Simple left/right inset guides so wrap boundaries are easy to inspect.
        let leftGuidePath = CGMutablePath()
        let rightGuidePath = CGMutablePath()
        let leftGuideX: CGFloat = {
            if let minX = lineRectsInContent.map({ $0.minX }).min(), minX.isFinite {
                return minX
            }
            return TokenSpacingInvariantSource.leftGuideX(in: self)
        }()
        let rightGuideX: CGFloat = {
            if let maxX = lineRectsInContent.map({ $0.maxX }).max(), maxX.isFinite {
                return maxX
            }
            // Approximate wrap boundary when no line rects exist.
            return max(leftGuideX, TokenSpacingInvariantSource.rightGuideX(in: self))
        }()
        if contentSize.height.isFinite, contentSize.height > 0 {
            leftGuidePath.move(to: CGPoint(x: leftGuideX, y: 0))
            leftGuidePath.addLine(to: CGPoint(x: leftGuideX, y: contentSize.height))

            rightGuidePath.move(to: CGPoint(x: rightGuideX, y: 0))
            rightGuidePath.addLine(to: CGPoint(x: rightGuideX, y: contentSize.height))
        }

        let alignedHeadwordPath = CGMutablePath()
        let misalignedHeadwordPath = CGMutablePath()
        let alignedRubyPath = CGMutablePath()
        let misalignedRubyPath = CGMutablePath()

        struct BisectorKey: Hashable {
            // kind 0: semantic token index + ruby display range, kind 1: ruby display range
            let kind: UInt8
            let tokenIndex: Int
            let loc: Int
            let len: Int
        }
        var seen: Set<BisectorKey> = []
        seen.reserveCapacity(min(1024, rubyLayers.count))

        // Debug readability: compact mode reduces the number of drawn bisectors.
        // When enabled, aligned runs draw only ONE yellow bisector (headword), while
        // misaligned runs still draw both (green) so the offset is visible.
        // Default is false (full detail): draw both headword + ruby bisectors.
        let compactBisectors = UserDefaults.standard.bool(forKey: "RubyDebug.compactBisectors")

        let tolerance: CGFloat = 0.75
        let maxLayers = min(rubyLayers.count, 1024)

        let displayText = attributedText.string as NSString
        let displayDoc = NSRange(location: 0, length: displayText.length)

        func isPunctuationOrSymbolOnly(_ s: String) -> Bool {
            if s.isEmpty { return false }
            if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            let set = CharacterSet.punctuationCharacters.union(.symbols)
            for scalar in s.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
                if set.contains(scalar) == false { return false }
            }
            return true
        }

        func isPunctuationOrSymbolOnlyDisplayRange(_ range: NSRange) -> Bool {
            let bounded = NSIntersectionRange(range, displayDoc)
            guard bounded.location != NSNotFound, bounded.length > 0 else { return false }
            let raw = displayText.substring(with: bounded)
            let cleaned = raw
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.isEmpty == false else { return false }
            return isPunctuationOrSymbolOnly(cleaned)
        }

        for i in 0..<maxLayers {
            guard let ruby = rubyLayers[i] as? CATextLayer else { continue }
            let rubyRect = ruby.frame
            guard rubyRect.isNull == false, rubyRect.isEmpty == false else { continue }

            guard let loc = ruby.value(forKey: "rubyRangeLocation") as? Int,
                  let len = ruby.value(forKey: "rubyRangeLength") as? Int,
                  loc != NSNotFound,
                  len > 0 else {
                continue
            }

            let range = NSRange(location: loc, length: len)

            // Bisectors are only meaningful for headword glyphs; skip punctuation-only ranges
            // (e.g. 、。) to avoid “extra” bisectors between words.
            if isPunctuationOrSymbolOnlyDisplayRange(range) {
                continue
            }

            // Deduplicate bisectors: a single semantic token can map to multiple ruby layers
            // (e.g. if attributes are split by padding/spacers). Drawing each layer's bisector
            // produces the “extra lines” effect without adding signal.
            let key: BisectorKey = {
                if let tokenIndex = ruby.value(forKey: "rubyTokenIndex") as? Int {
                    return BisectorKey(kind: 0, tokenIndex: tokenIndex, loc: loc, len: len)
                }
                return BisectorKey(kind: 1, tokenIndex: 0, loc: loc, len: len)
            }()
            if seen.contains(key) { continue }
            seen.insert(key)

            let baseRects = textKit2AnchorRectsInContentCoordinates(for: range, lineRectsInContent: lineRectsInContent)
            guard baseRects.isEmpty == false else { continue }
            let unions = unionRectsByLine(baseRects)
            guard unions.isEmpty == false else { continue }

            // Select the base union that this ruby layer was placed from.
            // IMPORTANT: Ruby rects sit above the typographic line rects, so intersection-based
            // line matching is unstable. Instead, we store the base union's midY on the ruby layer.
            let baseUnion: CGRect = {
                let storedMidY: CGFloat? = {
                    if let n = ruby.value(forKey: "rubyAnchorBaseMidY") as? NSNumber {
                        return CGFloat(n.doubleValue)
                    }
                    if let d = ruby.value(forKey: "rubyAnchorBaseMidY") as? Double {
                        return CGFloat(d)
                    }
                    return nil
                }()

                guard let targetMidY = storedMidY, unions.count > 1 else { return unions[0] }

                var best = unions[0]
                var bestDist = abs(best.midY - targetMidY)
                for u in unions.dropFirst() {
                    let dist = abs(u.midY - targetMidY)
                    if dist < bestDist {
                        bestDist = dist
                        best = u
                    }
                }
                return best
            }()

            let (baseRefX, rubyRefX): (CGFloat, CGFloat) = {
                if let xr = caretXRangeInContentCoordinates(for: range) {
                    switch rubyHorizontalAlignment {
                    case .leading:
                        return (xr.startX, rubyRect.minX)
                    case .center:
                        let mid = xr.startX + ((xr.endX - xr.startX) / 2.0)
                        return (mid, rubyRect.midX)
                    }
                }

                switch rubyHorizontalAlignment {
                case .leading:
                    return (baseUnion.minX, rubyRect.minX)
                case .center:
                    return (baseUnion.midX, rubyRect.midX)
                }
            }()

            let aligned = abs(baseRefX - rubyRefX) <= tolerance

            // Headword bisector.
            if drawHeadwordBisectors {
                let headwordPath = aligned ? alignedHeadwordPath : misalignedHeadwordPath
                headwordPath.move(to: CGPoint(x: baseRefX, y: baseUnion.minY))
                headwordPath.addLine(to: CGPoint(x: baseRefX, y: baseUnion.maxY))
            }

            // Ruby bisector.
            // In compact mode, skip aligned ruby bisectors to reduce visual clutter.
            if drawRubyBisectors {
                if aligned {
                    if compactBisectors == false {
                        alignedRubyPath.move(to: CGPoint(x: rubyRefX, y: rubyRect.minY))
                        alignedRubyPath.addLine(to: CGPoint(x: rubyRefX, y: rubyRect.maxY))
                    }
                } else {
                    misalignedRubyPath.move(to: CGPoint(x: rubyRefX, y: rubyRect.minY))
                    misalignedRubyPath.addLine(to: CGPoint(x: rubyRefX, y: rubyRect.maxY))
                }
            }
        }

        func apply(_ layer: CAShapeLayer, _ path: CGPath) {
            layer.frame = rubyBisectorDebugContainerLayer.bounds
            layer.path = path
            layer.isHidden = path.isEmpty
        }

        apply(rubyBisectorHeadwordAlignedLayer, alignedHeadwordPath)
        apply(rubyBisectorHeadwordMisalignedLayer, misalignedHeadwordPath)
        apply(rubyBisectorRubyAlignedLayer, alignedRubyPath)
        apply(rubyBisectorRubyMisalignedLayer, misalignedRubyPath)

        rubyBisectorLeftGuideLayer.frame = rubyBisectorDebugContainerLayer.bounds
        rubyBisectorLeftGuideLayer.path = leftGuidePath
        rubyBisectorLeftGuideLayer.isHidden = leftGuidePath.isEmpty

        rubyBisectorRightGuideLayer.frame = rubyBisectorDebugContainerLayer.bounds
        rubyBisectorRightGuideLayer.path = rightGuidePath
        rubyBisectorRightGuideLayer.isHidden = rightGuidePath.isEmpty

        rubyBisectorDebugContainerLayer.isHidden =
            alignedHeadwordPath.isEmpty &&
            misalignedHeadwordPath.isEmpty &&
            alignedRubyPath.isEmpty &&
            misalignedRubyPath.isEmpty &&
            leftGuidePath.isEmpty &&
            rightGuidePath.isEmpty
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
            rubyResolvedFramesByRunStart = [:]
            rubyBoundingRectsLayer.path = nil
            rubyBoundingRectsLayer.isHidden = true
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
            rubyResolvedFramesByRunStart = [:]
            rubyBoundingRectsLayer.path = nil
            rubyBoundingRectsLayer.isHidden = true
            rubyOverlayDirty = false
            lastRubyOverlayLayoutSignature = signature
            return
        }

        let headroom = max(0, rubyHighlightHeadroom)
        guard headroom > 0 else {
            rubyOverlayContainerLayer.sublayers = nil
            rubyResolvedFramesByRunStart = [:]
            rubyBoundingRectsLayer.path = nil
            rubyBoundingRectsLayer.isHidden = true
            rubyOverlayDirty = false
            lastRubyOverlayLayoutSignature = signature
            return
        }

        // Ensure TextKit 2 has laid out the whole document so segment rects are stable.
        suppressTextKit2LayoutCallbacks = true
        defer { suppressTextKit2LayoutCallbacks = false }
        layoutIfNeeded()
        if let tlm = textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
        }

        // Content-space anchors for content-space overlays (no contentOffset involvement).
        let lineRectsInContent = textKit2LineTypographicRectsInContentCoordinates()

        struct RubyPlacementProposal {
            let lineIndex: Int
            var frame: CGRect
            let preferredCenterX: CGFloat
            let anchorBaseMidY: CGFloat
        }

        var proposals: [RubyPlacementProposal] = []
        proposals.reserveCapacity(min(2048, cachedRubyRuns.count))
        var proposalRuns: [RubyRun] = []
        proposalRuns.reserveCapacity(min(2048, cachedRubyRuns.count))

        for run in cachedRubyRuns {
            let baseRectsInContent = textKit2AnchorRectsInContentCoordinates(for: run.inkRange, lineRectsInContent: lineRectsInContent)
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
                // Use inkRange start, not the raw ruby attribute range start.
                // When headword padding is enabled, the attribute range can include spacer glyphs
                // that may land on a different soft-wrapped line; anchoring to those creates
                // systematic bisector/ruby alignment drift.
                let startIndex = run.inkRange.location
                guard ns.length > 0, startIndex >= 0, startIndex < ns.length else {
                    return unionsInContent[0]
                }

                let firstComposed = ns.rangeOfComposedCharacterSequence(at: startIndex)
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
            let size = RubyText.measureTypographicSize(NSAttributedString(string: run.reading, attributes: attrs))
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { continue }

            let baseUnionInContent = preferredUnionInContent
            let gap = max(0, self.rubyBaselineGap)
            // Center ruby over the base glyph bounds.
            // (If we shift ruby to eliminate left overhang, the extra width appears only on the right.)
            let xUnclamped: CGFloat = {
                // Prefer caret geometry (ink-only) so ruby stays centered over visible glyphs.
                if let xr = caretXRangeInContentCoordinates(for: run.inkRange) {
                    switch rubyHorizontalAlignment {
                    case .leading:
                        return xr.startX
                    case .center:
                        let baseWidth = max(0, xr.endX - xr.startX)
                        return xr.startX + ((baseWidth - size.width) / 2.0)
                    }
                }
                // Fallback to anchor rect unions if caret geometry is unavailable.
                switch rubyHorizontalAlignment {
                case .leading:
                    return baseUnionInContent.minX
                case .center:
                    return baseUnionInContent.midX - (size.width / 2.0)
                }
            }()

            let x: CGFloat = clampRubyXInContentCoordinates(xUnclamped, width: size.width)
            // Place ruby in the reserved headroom above the base glyph bounds.
            // This avoids the ruby being occluded by the text layer when overlays are below it.
            let y = (baseUnionInContent.minY - gap) - size.height

            let initialFrame = CGRect(x: x, y: y, width: size.width, height: size.height)
            let lineIndex: Int = bestMatchingLineIndex(for: baseUnionInContent, candidates: lineRectsInContent)
                ?? (Int.min + proposals.count)
            let preferredCenterX: CGFloat = x + (size.width / 2.0)
            proposals.append(.init(
                lineIndex: lineIndex,
                frame: initialFrame,
                preferredCenterX: preferredCenterX,
                anchorBaseMidY: baseUnionInContent.midY
            ))
            proposalRuns.append(run)
        }

        // NOTE: We intentionally do NOT perform collision resolution here.
        // Shifting ruby frames to avoid overlap necessarily de-centers them from headwords.

        var layers: [CALayer] = []
        layers.reserveCapacity(min(2048, proposals.count))

        var resolvedFramesByRunStart: [Int: CGRect] = [:]
        resolvedFramesByRunStart.reserveCapacity(min(2048, proposals.count))

        for (idx, proposal) in proposals.enumerated() {
            let run = proposalRuns[idx]

            let rubyPointSize = max(1.0, run.fontSize)
            let rubyFont = (self.font ?? UIFont.systemFont(ofSize: rubyPointSize)).withSize(rubyPointSize)

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
            textLayer.setValue(run.inkRange.location, forKey: "rubyRangeLocation")
            textLayer.setValue(run.inkRange.length, forKey: "rubyRangeLength")
            // Store anchor metadata for stable debug/bisector matching.
            // (Ruby rects do not intersect typographic line rects, so geometric matching is fragile.)
            textLayer.setValue(NSNumber(value: Double(proposal.preferredCenterX)), forKey: "rubyPreferredCenterX")
            textLayer.setValue(NSNumber(value: Double(proposal.anchorBaseMidY)), forKey: "rubyAnchorBaseMidY")
            // IMPORTANT (2026-01-28): When headword padding is enabled, ruby-bearing runs can
            // begin with one or more invisible width spacer characters (U+FFFC). Those indices
            // are not real source text and `displayToSource` maps them to the previous source
            // index, which mis-tags ruby layers and can make ruby-envelope highlight collection
            // empty. Fix: choose the first non-spacer display index within the run.
            let tokenLookupDisplayIndex: Int = {
                guard run.inkRange.location != NSNotFound, run.inkRange.length > 0 else { return run.inkRange.location }
                let upper = min(attributedText?.length ?? 0, NSMaxRange(run.inkRange))
                var idx = max(0, run.inkRange.location)
                while idx < upper {
                    if isRubyWidthSpacer(atDisplayIndex: idx) == false {
                        return idx
                    }
                    idx += 1
                }
                return run.inkRange.location
            }()
            let sourceLoc = sourceIndex(fromDisplayIndex: tokenLookupDisplayIndex)
            if let (tokenIndex, span) = semanticSpans.spanContext(containingUTF16Index: sourceLoc) {
                textLayer.setValue(tokenIndex, forKey: "rubyTokenIndex")
                textLayer.setValue(span.range.location, forKey: "rubySpanLocation")
                textLayer.setValue(span.range.length, forKey: "rubySpanLength")
            }
            textLayer.frame = proposal.frame
            resolvedFramesByRunStart[run.inkRange.location] = proposal.frame
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
        rubyResolvedFramesByRunStart = resolvedFramesByRunStart
        updateRubyBoundingRects(resolvedFramesByRunStart: resolvedFramesByRunStart)
        rubyOverlayDirty = false
        lastRubyOverlayLayoutSignature = signature
    }

    func applyAttributedText(_ text: NSAttributedString) {
        if let current = attributedText, current.isEqual(to: text) {
            // No change; avoid resetting attributedText which would dismiss menus.
            return
        }
        let applyStart = CustomLogger.perfStart()
        let savedOffset = contentOffset
        let wasFirstResponder = isFirstResponder
        let oldSelectedRange = selectedRange
        attributedText = text
        hasDebugDictionaryCoverageAttributes = containsDebugDictionaryCoverageAttribute(in: text)
        attributedTextRevision &+= 1
        rebuildRubyRunCache(from: text)
        rubyOverlayDirty = true
        if wasFirstResponder {
            _ = becomeFirstResponder()
            let newLength = attributedText?.length ?? 0
            if oldSelectedRange.location != NSNotFound, NSMaxRange(oldSelectedRange) <= newLength {
                selectedRange = oldSelectedRange
            }
        }

        // Setting attributedText can snap scroll positions; restore a stable offset.
        // IMPORTANT: When horizontal scrolling is not meaningful, always keep the visible
        // left edge stable (x = -adjustedContentInset.left).
        layoutIfNeeded()
        let allowHorizontal = horizontalScrollEnabled && (wrapLines == false)
        let inset = adjustedContentInset
        let minX = -inset.left
        let maxX = max(minX, contentSize.width - bounds.width + inset.right)
        let targetX: CGFloat = allowHorizontal ? min(max(savedOffset.x, minX), maxX) : minX

        var target = contentOffset
        target.x = targetX
        if isScrollEnabled {
            let minY = -inset.top
            let maxY = max(minY, contentSize.height - bounds.height + inset.bottom)
            target.y = min(max(savedOffset.y, minY), maxY)
        }
        if (target.x - contentOffset.x).magnitude > 0.5 || (target.y - contentOffset.y).magnitude > 0.5 {
            setContentOffset(target, animated: false)
        }

        // Overlays are laid out during `layoutSubviews()`. If we were temporarily snapped during
        // the attributedText update, ensure we lay out overlays again after restoring offsets.
        rubyOverlayDirty = true
        setNeedsLayout()
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
        CustomLogger.shared.perf(
            "TokenOverlayTextView.applyAttributedText",
            elapsedMS: CustomLogger.perfElapsedMS(since: applyStart),
            details: "length=\(text.length) semantic=\(semanticSpans.count)",
            thresholdMS: 4.0,
            level: .debug
        )
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

            // Derive an "ink" range for geometry/bisectors by trimming invisible ruby-width
            // spacers (U+FFFC) and pure whitespace at the start/end of the attributed run.
            // This keeps alignment debugging tied to the visible glyphs, even when we pad
            // headword spacing for wide ruby.
            let backing = text.string as NSString
            let upperBound = min(text.length, NSMaxRange(range))
            guard let inkRange = TokenSpacingInvariantSource.trimmedInkRange(
                in: range,
                attributedLength: text.length,
                backing: backing
            ) else {
                // This ruby attribute range contains only hard-boundary glyphs (e.g. U+FFFC
                // padding spacers / whitespace / punctuation). These can be introduced by
                // headword padding logic and should not generate ruby overlays/bisectors.
                return
            }

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
            let upper = upperBound
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
            runs.append(RubyRun(range: range, inkRange: inkRange, reading: reading, fontSize: rubyFontSize, color: color))
        }

        cachedRubyRuns = runs
    }


    func logOnScreenWidthsIfPossible(for selection: RubySpanSelection) {
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

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === tokenSpacingPanRecognizer {
            return shouldBeginTokenSpacingPan()
        }
        return true
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

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        shouldBreakLineBefore location: NSTextLocation,
        hyphenating: Bool
    ) -> Bool {
        guard wrapLines else { return true }

        guard let tcm = textLayoutManager.textContentManager else { return true }
        let docStart = textLayoutManager.documentRange.location
        let charIndex = tcm.offset(from: docStart, to: location)
        return shouldAllowWordBreakBeforeCharacter(at: charIndex)
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
