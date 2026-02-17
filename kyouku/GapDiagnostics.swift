import UIKit

#if DEBUG

enum GapDiagnostics {
    static let autoRunOnce = ProcessInfo.processInfo.environment["GAP_DIAGNOSTICS"] == "1"

    private static var lastCycleToken: Int?
    private static var inProgress = false

    struct SegmentItem {
        let lineIndex: Int
        let displayRange: NSRange
        let surface: String
        let minX: CGFloat
        let maxX: CGFloat
    }

    private struct BoundaryKey: Hashable {
        let prevEnd: Int
        let nextStart: Int
    }

    private struct BoundaryObservation {
        let key: BoundaryKey
        let label: String
        let baselineGap: CGFloat
        let prevOriginX: CGFloat
        let nextOriginX: CGFloat
    }

    static func runAutoVerdictsIfNeeded(
        view: TokenOverlayTextView,
        cycleToken: Int,
        segmentsByLine: [Int: [SegmentItem]],
        leftGuideX: CGFloat,
        rightGuideX: CGFloat,
        attributedText: NSAttributedString
    ) {
        guard autoRunOnce else { return }
        guard inProgress == false else { return }
        if lastCycleToken == cycleToken { return }
        lastCycleToken = cycleToken

        let baseline = collectBaselineObservations(view: view, segmentsByLine: segmentsByLine)
        guard baseline.isEmpty == false else { return }

        if let firstBoundary = firstNonZeroBoundary(segmentsByLine: segmentsByLine) {
            logRawVsHighlight(
                view: view,
                prev: firstBoundary.prev,
                next: firstBoundary.next,
                highlightGap: firstBoundary.gap
            )
        }

        inProgress = true
        view.gapDiagnosticsInProgress = true
        defer {
            view.gapDiagnosticsInProgress = false
            inProgress = false
        }

        let originalInset = view.textContainerInset
        let originalPadding = view.textContainer.lineFragmentPadding
        let originalText = NSAttributedString(attributedString: attributedText)

        let forcedLeftText = makeForcedLeftAlignmentCopy(from: attributedText)
        view.applyAttributedText(forcedLeftText)
        view.layoutIfNeeded()

        let forcedLineRects = view.textKit2LineTypographicRectsInContentCoordinates(visibleOnly: true)
        let forcedSegmentsByLine = recomputeSegmentsByLine(view: view, lineRectsInContent: forcedLineRects)
        let forcedGapByKey = collectGapByBoundaryKey(segmentsByLine: forcedSegmentsByLine)

        view.textContainerInset = originalInset
        view.textContainer.lineFragmentPadding = originalPadding
        view.applyAttributedText(originalText)
        view.layoutIfNeeded()

        for obs in baseline {
            let forcedGap = forcedGapByKey[obs.key] ?? obs.baselineGap
            let justificationConfirmed = abs(obs.baselineGap) > 0.01 && abs(forcedGap) < 0.05
            let coordinateMismatch = abs(obs.prevOriginX - obs.nextOriginX) > 0.01

            CustomLogger.shared.print(
                String(
                    format: "[GapDiag] VERDICT boundary=\"%@\" baselineGap=%.2f forcedLeftGap=%.2f justificationConfirmed=%@ coordinateMismatch=%@ fragmentOriginPrev=%.2f fragmentOriginNext=%.2f leftGuide=%.2f rightGuide=%.2f",
                    obs.label,
                    obs.baselineGap,
                    forcedGap,
                    justificationConfirmed ? "true" : "false",
                    coordinateMismatch ? "true" : "false",
                    obs.prevOriginX,
                    obs.nextOriginX,
                    leftGuideX,
                    rightGuideX
                )
            )

            if coordinateMismatch {
                CustomLogger.shared.print("[GapDiag] COORDINATE_MISMATCH=true")
            }
        }
    }

    private struct BoundaryPair {
        let prev: SegmentItem
        let next: SegmentItem
        let gap: CGFloat
    }

    private static func firstNonZeroBoundary(segmentsByLine: [Int: [SegmentItem]]) -> BoundaryPair? {
        for lineIndex in segmentsByLine.keys.sorted() {
            guard let segments = segmentsByLine[lineIndex], segments.count >= 2 else { continue }
            let ordered = segments.sorted { a, b in
                if abs(a.minX - b.minX) > TokenSpacingInvariantSource.positionTieTolerance {
                    return a.minX < b.minX
                }
                return a.maxX < b.maxX
            }

            for i in 1..<ordered.count {
                let prev = ordered[i - 1]
                let next = ordered[i]
                let gap = next.minX - prev.maxX
                if abs(gap) > 0.01 {
                    return BoundaryPair(prev: prev, next: next, gap: gap)
                }
            }
        }
        return nil
    }

    private static func logRawVsHighlight(
        view: TokenOverlayTextView,
        prev: SegmentItem,
        next: SegmentItem,
        highlightGap: CGFloat
    ) {
        let rawPrev = rawMetrics(view: view, displayRange: prev.displayRange)
        let rawNext = rawMetrics(view: view, displayRange: next.displayRange)

        guard let rawPrevMaxX = rawPrev.maxX,
              let rawNextMinX = rawNext.minX else {
            return
        }

        let rawGap = rawNextMinX - rawPrevMaxX

        CustomLogger.shared.print(
            String(
                format: "[GapDiag] RAW prev=\"%@\" glyphRange=%@ sumAdvances=%.2f finalMaxX=%.2f rawPrevMaxX=%.2f",
                prev.surface,
                NSStringFromRange(rawPrev.rangeUsed),
                rawPrev.sumAdvances,
                rawPrev.finalMaxX,
                rawPrevMaxX
            )
        )
        CustomLogger.shared.print(
            String(
                format: "[GapDiag] RAW next=\"%@\" glyphRange=%@ sumAdvances=%.2f finalMaxX=%.2f rawNextMinX=%.2f",
                next.surface,
                NSStringFromRange(rawNext.rangeUsed),
                rawNext.sumAdvances,
                rawNext.finalMaxX,
                rawNextMinX
            )
        )
        CustomLogger.shared.print(
            String(
                format: "[GapDiag] HIGHLIGHT prev=\"%@\" next=\"%@\" highlightPrevMaxX=%.2f highlightNextMinX=%.2f highlightGap=%.2f",
                prev.surface,
                next.surface,
                prev.maxX,
                next.minX,
                highlightGap
            )
        )
        CustomLogger.shared.print(
            String(
                format: "[GapDiag] RAW_VS_HIGHLIGHT rawGap=%.2f highlightGap=%.2f",
                rawGap,
                highlightGap
            )
        )

        logIntermediateGlyphProbe(
            view: view,
            prev: prev,
            next: next
        )
    }

    private struct GlyphUnit {
        let glyphIndex: Int
        let characterIndex: Int
        let characterRange: NSRange
        let advanceWidth: CGFloat
        let unicodeHex: String
        let isWhitespace: Bool
        let isControl: Bool
        let isAttachment: Bool
    }

    private static func logIntermediateGlyphProbe(
        view: TokenOverlayTextView,
        prev: SegmentItem,
        next: SegmentItem
    ) {
        guard let attributed = view.attributedText,
              let tlm = view.textLayoutManager,
              let tcm = tlm.textContentManager else {
            return
        }

        let docStart = tlm.documentRange.location
        let docLength = attributed.length
        let windowStart = max(0, min(prev.displayRange.location, next.displayRange.location) - 4)
        let windowEnd = min(docLength, max(NSMaxRange(prev.displayRange), NSMaxRange(next.displayRange)) + 4)
        guard windowEnd > windowStart else { return }

        guard let startLoc = tcm.location(docStart, offsetBy: windowStart),
              let endLoc = tcm.location(docStart, offsetBy: windowEnd),
              let textRange = NSTextRange(location: startLoc, end: endLoc) else {
            return
        }

        tlm.ensureLayout(for: textRange)

        var units: [GlyphUnit] = []
        units.reserveCapacity(32)

        let ns = attributed.string as NSString

        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { segmentRange, rect, _, _ in
            guard let segmentRange else { return true }
            let start = tcm.offset(from: docStart, to: segmentRange.location)
            let end = tcm.offset(from: docStart, to: segmentRange.endLocation)
            let len = max(0, end - start)
            guard len > 0 else { return true }
            let charRange = NSRange(location: start, length: len)
            guard NSMaxRange(charRange) <= ns.length else { return true }

            let segmentText = ns.substring(with: charRange)
            let hex = segmentText.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: ",")
            let isWhitespace = segmentText.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            let isControl = segmentText.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            let isAttachment = {
                if segmentText == "\u{FFFC}" { return true }
                if attributed.attribute(kCTRunDelegateAttributeName as NSAttributedString.Key, at: charRange.location, effectiveRange: nil) != nil {
                    return true
                }
                return false
            }()

            units.append(
                GlyphUnit(
                    glyphIndex: units.count,
                    characterIndex: charRange.location,
                    characterRange: charRange,
                    advanceWidth: rect.width,
                    unicodeHex: hex,
                    isWhitespace: isWhitespace,
                    isControl: isControl,
                    isAttachment: isAttachment
                )
            )
            return true
        }

        guard units.isEmpty == false else { return }

        func glyphRange(for displayRange: NSRange) -> NSRange? {
            var first: Int?
            var last: Int?
            for u in units {
                if NSIntersectionRange(u.characterRange, displayRange).length > 0 {
                    first = min(first ?? u.glyphIndex, u.glyphIndex)
                    last = max(last ?? u.glyphIndex, u.glyphIndex)
                }
            }
            guard let first, let last else { return nil }
            return NSRange(location: first, length: (last - first + 1))
        }

        guard let prevGlyphRange = glyphRange(for: prev.displayRange),
              let nextGlyphRange = glyphRange(for: next.displayRange) else {
            return
        }

        let prevGlyphEndIndex = NSMaxRange(prevGlyphRange) - 1
        let nextGlyphStartIndex = nextGlyphRange.location
        let glyphIndexDelta = nextGlyphStartIndex - prevGlyphEndIndex

        CustomLogger.shared.print(
            String(
                format: "[GapDiag] GLYPH_BOUNDARY prevGlyphRange=%@ nextGlyphRange=%@ prevGlyphEndIndex=%d nextGlyphStartIndex=%d glyphIndexDelta=%d note=TextKit2 has no public legacy glyph index; glyphIndex is segment-order proxy",
                NSStringFromRange(prevGlyphRange),
                NSStringFromRange(nextGlyphRange),
                prevGlyphEndIndex,
                nextGlyphStartIndex,
                glyphIndexDelta
            )
        )

        let fromIndex = max(0, prevGlyphEndIndex - 1)
        let toIndex = min(units.count - 1, nextGlyphStartIndex + 1)
        if fromIndex <= toIndex {
            for idx in fromIndex...toIndex {
                let u = units[idx]
                CustomLogger.shared.print(
                    String(
                        format: "[GapDiag] GLYPH glyphIndex=%d characterIndex=%d unicodeScalars=[%@] advanceWidth=%.2f isWhitespace=%@ isControl=%@ isAttachment=%@ isElastic=n/a isHidden=n/a",
                        u.glyphIndex,
                        u.characterIndex,
                        u.unicodeHex,
                        u.advanceWidth,
                        u.isWhitespace ? "true" : "false",
                        u.isControl ? "true" : "false",
                        u.isAttachment ? "true" : "false"
                    )
                )
            }
        }

        if glyphIndexDelta > 1 {
            CustomLogger.shared.print("[GapDiag] INTERMEDIATE_GLYPH_DETECTED=true")
        }
    }

    private struct RawMetrics {
        let rangeUsed: NSRange
        let sumAdvances: CGFloat
        let finalMaxX: CGFloat
        let minX: CGFloat?
        let maxX: CGFloat?
    }

    private static func rawMetrics(view: TokenOverlayTextView, displayRange: NSRange) -> RawMetrics {
        let rects = view.textKit2SegmentRectsInContentCoordinates(for: displayRange)
        guard rects.isEmpty == false else {
            return RawMetrics(rangeUsed: displayRange, sumAdvances: 0, finalMaxX: .nan, minX: nil, maxX: nil)
        }

        let ordered = rects.sorted { a, b in
            if abs(a.minX - b.minX) > TokenSpacingInvariantSource.positionTieTolerance {
                return a.minX < b.minX
            }
            return a.maxX < b.maxX
        }

        var sumAdvances: CGFloat = 0
        var minX: CGFloat?
        var maxX: CGFloat?
        for r in ordered {
            sumAdvances += r.width
            minX = min(minX ?? r.minX, r.minX)
            maxX = max(maxX ?? r.maxX, r.maxX)
        }

        return RawMetrics(
            rangeUsed: displayRange,
            sumAdvances: sumAdvances,
            finalMaxX: maxX ?? .nan,
            minX: minX,
            maxX: maxX
        )
    }

    private static func collectBaselineObservations(
        view: TokenOverlayTextView,
        segmentsByLine: [Int: [SegmentItem]]
    ) -> [BoundaryObservation] {
        var out: [BoundaryObservation] = []
        out.reserveCapacity(64)

        for lineIndex in segmentsByLine.keys.sorted() {
            guard let segments = segmentsByLine[lineIndex], segments.count >= 2 else { continue }

            let ordered = segments.sorted { a, b in
                if abs(a.minX - b.minX) > TokenSpacingInvariantSource.positionTieTolerance {
                    return a.minX < b.minX
                }
                return a.maxX < b.maxX
            }

            for i in 1..<ordered.count {
                let prev = ordered[i - 1]
                let next = ordered[i]
                let gap = next.minX - prev.maxX
                if abs(gap) <= 0.01 { continue }

                let key = BoundaryKey(
                    prevEnd: NSMaxRange(prev.displayRange),
                    nextStart: next.displayRange.location
                )
                let label = "\(prev.surface)|\(next.surface)"
                let prevOriginX = fragmentOriginX(view: view, displayIndex: max(prev.displayRange.location, NSMaxRange(prev.displayRange) - 1))
                let nextOriginX = fragmentOriginX(view: view, displayIndex: next.displayRange.location)

                out.append(
                    BoundaryObservation(
                        key: key,
                        label: label,
                        baselineGap: gap,
                        prevOriginX: prevOriginX,
                        nextOriginX: nextOriginX
                    )
                )
            }
        }

        return out
    }

    private static func collectGapByBoundaryKey(
        segmentsByLine: [Int: [SegmentItem]]
    ) -> [BoundaryKey: CGFloat] {
        var out: [BoundaryKey: CGFloat] = [:]
        out.reserveCapacity(128)

        for lineIndex in segmentsByLine.keys.sorted() {
            guard let segments = segmentsByLine[lineIndex], segments.count >= 2 else { continue }

            let ordered = segments.sorted { a, b in
                if abs(a.minX - b.minX) > TokenSpacingInvariantSource.positionTieTolerance {
                    return a.minX < b.minX
                }
                return a.maxX < b.maxX
            }

            for i in 1..<ordered.count {
                let prev = ordered[i - 1]
                let next = ordered[i]
                let key = BoundaryKey(
                    prevEnd: NSMaxRange(prev.displayRange),
                    nextStart: next.displayRange.location
                )
                out[key] = next.minX - prev.maxX
            }
        }

        return out
    }

    private static func makeForcedLeftAlignmentCopy(from text: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: mutable.length)

        mutable.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
            let source = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
            let style = source.mutableCopy() as! NSMutableParagraphStyle
            style.alignment = .left
            style.lineBreakMode = .byWordWrapping
            if #available(iOS 14.0, *) {
                style.lineBreakStrategy = []
            }
            mutable.addAttribute(.paragraphStyle, value: style, range: range)
        }

        return mutable
    }

    private static func recomputeSegmentsByLine(
        view: TokenOverlayTextView,
        lineRectsInContent: [CGRect]
    ) -> [Int: [SegmentItem]] {
        var segmentsByLine: [Int: [SegmentItem]] = [:]
        segmentsByLine.reserveCapacity(lineRectsInContent.count)

        for span in view.semanticSpans {
            let displayRange = view.displayRange(fromSourceRange: span.range)
            guard displayRange.location != NSNotFound, displayRange.length > 0 else { continue }

            let baseRects = view.baseHighlightRectsInContentCoordinatesExcludingRubySpacers(in: displayRange)
            guard baseRects.isEmpty == false else { continue }
            let unions = view.unionRectsByLine(baseRects)
            guard unions.isEmpty == false else { continue }

            for unionRect in unions {
                guard let lineIndex = view.bestMatchingLineIndex(for: unionRect, candidates: lineRectsInContent) else { continue }
                segmentsByLine[lineIndex, default: []].append(
                    SegmentItem(
                        lineIndex: lineIndex,
                        displayRange: displayRange,
                        surface: span.surface,
                        minX: unionRect.minX,
                        maxX: unionRect.maxX
                    )
                )
            }
        }

        return segmentsByLine
    }

    private static func fragmentOriginX(view: TokenOverlayTextView, displayIndex: Int) -> CGFloat {
        guard let tlm = view.textLayoutManager,
              let tcm = tlm.textContentManager,
              displayIndex >= 0 else {
            return .nan
        }

        let docStart = tlm.documentRange.location
        guard let location = tcm.location(docStart, offsetBy: displayIndex),
              let fragment = tlm.textLayoutFragment(for: location) else {
            return .nan
        }

        return fragment.layoutFragmentFrame.origin.x
    }
}

#endif
