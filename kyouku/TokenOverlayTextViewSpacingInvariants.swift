import UIKit

enum TokenSpacingInvariantID {
    case leftBoundary
    case rightBoundary
    case nonOverlap
    case gapMatchesKern
    case rubyOverlapResolution
}

enum TokenSpacingInvariantSource {
    private static let flushEpsilon: CGFloat = 0.01
    private static let spacingTelemetryDefaultsKey = "SpacingDebug.telemetry"

    static var spacingTelemetryEnabled: Bool {
        UserDefaults.standard.bool(forKey: spacingTelemetryDefaultsKey)
    }

    static func logSpacingTelemetry(_ message: String) {
        guard spacingTelemetryEnabled else { return }
        CustomLogger.shared.debug("[SpacingTelemetry] \(message)")
    }

    static func checkEnabled(_ invariant: TokenSpacingInvariantID) -> Bool {
        switch invariant {
        case .leftBoundary, .rightBoundary, .nonOverlap, .gapMatchesKern:
            return true
        case .rubyOverlapResolution:
            return false
        }
    }

    static func fixEnabled(_ invariant: TokenSpacingInvariantID) -> Bool {
        switch invariant {
        case .leftBoundary, .rightBoundary, .rubyOverlapResolution:
            return true
        case .nonOverlap, .gapMatchesKern:
            return false
        }
    }

    static func onePixel(in textView: TokenOverlayTextView) -> CGFloat {
        1.0 / max(1.0, textView.traitCollection.displayScale)
    }

    static func leftGuideX(in textView: TokenOverlayTextView) -> CGFloat {
        textView.textContainerInset.left + textView.textContainer.lineFragmentPadding
    }

    static func rightGuideX(in textView: TokenOverlayTextView) -> CGFloat {
        textView.textContainerInset.left + (textView.textContainer.size.width - textView.textContainer.lineFragmentPadding)
    }

    static func leftBoundaryTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        flushEpsilon
    }

    static func rightBoundaryTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        flushEpsilon
    }

    static func overlapTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        flushEpsilon
    }

    static func kernGapTolerance(in textView: TokenOverlayTextView) -> CGFloat {
        flushEpsilon
    }

    static func leftCrossingThreshold(in textView: TokenOverlayTextView) -> CGFloat {
        -flushEpsilon
    }

    static func alignedThreshold(in textView: TokenOverlayTextView) -> CGFloat {
        flushEpsilon
    }

    static var lineSpacerInsertionThreshold: CGFloat { flushEpsilon }
    static var lineSpacerResizeThreshold: CGFloat { flushEpsilon }
    static var rubyOverlapMinimumGap: CGFloat { flushEpsilon }
    static var positionTieTolerance: CGFloat { 0.5 }
    static var tokenSpacingExistingWidthEpsilon: CGFloat { 0.25 }
    static var tokenSpacingMinWidth: CGFloat { -60 }
    static var tokenSpacingMaxWidth: CGFloat { 120 }

    static func clampTokenSpacingWidth(_ width: CGFloat) -> CGFloat {
        max(tokenSpacingMinWidth, min(width, tokenSpacingMaxWidth))
    }

    static func resolveTokenSpacingBoundary(
        selection: RubySpanSelection,
        length: Int,
        backing: NSString,
        currentWidthProvider: ((Int) -> CGFloat)?
    ) -> Int? {
        let start = selection.highlightRange.location
        let end = NSMaxRange(selection.highlightRange)

        let leading: Int? = (start > 0 && start < length) ? start : nil
        let trailing: Int? = (end > 0 && end < length) ? end : nil
        guard leading != nil || trailing != nil else { return nil }

        func isNewlineBoundary(_ idx: Int) -> Bool {
            let scalar = backing.character(at: idx)
            if let u = UnicodeScalar(scalar), CharacterSet.newlines.contains(u) {
                return true
            }
            return false
        }

        let leadingOK = (leading != nil && isNewlineBoundary(leading!) == false)
        let trailingOK = (trailing != nil && isNewlineBoundary(trailing!) == false)
        guard leadingOK || trailingOK else { return nil }

        if let provider = currentWidthProvider {
            let leadingValue = (leadingOK && leading != nil) ? provider(leading!) : 0
            let trailingValue = (trailingOK && trailing != nil) ? provider(trailing!) : 0
            let hasLeading = abs(leadingValue) > tokenSpacingExistingWidthEpsilon
            let hasTrailing = abs(trailingValue) > tokenSpacingExistingWidthEpsilon

            if hasLeading && hasTrailing == false { return leading }
            if hasTrailing && hasLeading == false { return trailing }
        }

        if leadingOK, let leading { return leading }
        if trailingOK, let trailing { return trailing }
        return nil
    }

    static func isHardBoundaryGlyph(_ s: String) -> Bool {
        if s == "\u{FFFC}" { return true }
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let set = CharacterSet.punctuationCharacters.union(.symbols)
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            if set.contains(scalar) == false { return false }
        }
        return true
    }

    static func trimmedInkRange(
        in displayRange: NSRange,
        attributedLength: Int,
        backing: NSString
    ) -> NSRange? {
        let doc = NSRange(location: 0, length: attributedLength)
        let bounded = NSIntersectionRange(displayRange, doc)
        guard bounded.location != NSNotFound, bounded.length > 0 else { return nil }
        let upperBound = min(attributedLength, NSMaxRange(bounded))
        var inkStart = bounded.location
        var inkEndExclusive = upperBound
        var foundInkGlyph = false

        if bounded.location < upperBound {
            var idx = bounded.location
            while idx < upperBound {
                let r = backing.rangeOfComposedCharacterSequence(at: idx)
                guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= upperBound else { break }
                let s = backing.substring(with: r)
                if isHardBoundaryGlyph(s) {
                    idx = NSMaxRange(r)
                    continue
                }
                foundInkGlyph = true
                inkStart = r.location
                break
            }
            guard foundInkGlyph else { return nil }

            var tail = upperBound - 1
            while tail >= inkStart {
                let r = backing.rangeOfComposedCharacterSequence(at: tail)
                guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= upperBound else { break }
                let s = backing.substring(with: r)
                if isHardBoundaryGlyph(s) {
                    if r.location == 0 { break }
                    tail = r.location - 1
                    continue
                }
                inkEndExclusive = NSMaxRange(r)
                break
            }
        }

        let len = max(0, inkEndExclusive - inkStart)
        guard inkStart != NSNotFound, len > 0 else { return nil }
        return NSRange(location: inkStart, length: len)
    }

    static func trailingKern(in attributedText: NSAttributedString, inkRange: NSRange) -> CGFloat {
        guard inkRange.location != NSNotFound, inkRange.length > 0 else { return 0 }
        let backing = attributedText.string as NSString
        let last = max(inkRange.location, NSMaxRange(inkRange) - 1)
        guard last >= 0, last < backing.length else { return 0 }
        let composed = backing.rangeOfComposedCharacterSequence(at: last)
        guard composed.location != NSNotFound, composed.length > 0 else { return 0 }
        let v = attributedText.attribute(.kern, at: composed.location, effectiveRange: nil)
        if let num = v as? NSNumber { return CGFloat(num.doubleValue) }
        if let cg = v as? CGFloat { return cg }
        if let dbl = v as? Double { return CGFloat(dbl) }
        return 0
    }

    static func caretRectInContentCoordinates(
        in textView: TokenOverlayTextView,
        index: Int,
        attributedLength: Int
    ) -> CGRect? {
        guard index >= 0, index <= attributedLength else { return nil }
        guard let pos = textView.position(from: textView.beginningOfDocument, offset: index) else { return nil }
        let r = textView.caretRect(for: pos)
        if r.isNull || r.isEmpty { return nil }
        return r.offsetBy(dx: textView.contentOffset.x, dy: textView.contentOffset.y)
    }

    static func lineIndexForCaretRect(
        _ caretRectInContent: CGRect,
        lineRectsInContent: [CGRect],
        resolveLineIndex: (CGRect, [CGRect]) -> Int?
    ) -> Int? {
        guard lineRectsInContent.isEmpty == false else { return nil }
        let probe = CGRect(
            x: caretRectInContent.minX,
            y: caretRectInContent.minY,
            width: 1,
            height: max(1, caretRectInContent.height)
        )
        return resolveLineIndex(probe, lineRectsInContent)
    }

    struct InkTokenRecord {
        let tokenIndex: Int
        let sourceRange: NSRange
        let displayRange: NSRange
        let inkRange: NSRange
        let surface: String
    }

    static func collectInkTokenRecords(
        attributedText: NSAttributedString,
        semanticSpans: [SemanticSpan],
        maxTokens: Int,
        displayRangeFromSource: (NSRange) -> NSRange,
        shouldSkipDisplayRange: ((NSRange) -> Bool)? = nil
    ) -> [InkTokenRecord] {
        guard attributedText.length > 0 else { return [] }
        guard semanticSpans.isEmpty == false else { return [] }

        let backing = attributedText.string as NSString
        let upper = min(maxTokens, semanticSpans.count)
        if upper <= 0 { return [] }

        var records: [InkTokenRecord] = []
        records.reserveCapacity(min(upper, 1024))

        for tokenIndex in 0..<upper {
            let span = semanticSpans[tokenIndex]
            let sourceRange = span.range
            guard sourceRange.location != NSNotFound, sourceRange.length > 0 else { continue }
            if span.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

            let displayRange = displayRangeFromSource(sourceRange)
            guard displayRange.location != NSNotFound, displayRange.length > 0 else { continue }
            if shouldSkipDisplayRange?(displayRange) == true { continue }

            guard let inkRange = trimmedInkRange(
                in: displayRange,
                attributedLength: attributedText.length,
                backing: backing
            ) else { continue }

            records.append(
                InkTokenRecord(
                    tokenIndex: tokenIndex,
                    sourceRange: sourceRange,
                    displayRange: displayRange,
                    inkRange: inkRange,
                    surface: span.surface
                )
            )
        }

        return records
    }

    struct LeftBoundaryCandidate {
        let lineIndex: Int
        let tokenIndex: Int
        let displayStart: Int
        let envelopeMinX: CGFloat
        let baseMinX: CGFloat
        let snippet: String
    }

    enum BoundaryDirection: String {
        case left = "LEFT"
        case right = "RIGHT"
        case ok = "OK"
    }

    struct LeftBoundaryLineResult {
        let lineIndex: Int
        let tokenIndex: Int
        let displayStart: Int
        let tokenLeftX: CGFloat
        let baseLeftX: CGFloat
        let deltaX: CGFloat
        let direction: BoundaryDirection
        let isDeviation: Bool
        let snippet: String
    }

    static func evaluateLeftBoundaryLines(
        candidates: [LeftBoundaryCandidate],
        leftGuideX: CGFloat,
        alignedThreshold: CGFloat
    ) -> [LeftBoundaryLineResult] {
        guard candidates.isEmpty == false else { return [] }

        var firstByLine: [Int: LeftBoundaryCandidate] = [:]
        firstByLine.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let existing = firstByLine[candidate.lineIndex] {
                if candidate.envelopeMinX < (existing.envelopeMinX - positionTieTolerance) {
                    firstByLine[candidate.lineIndex] = candidate
                } else if abs(candidate.envelopeMinX - existing.envelopeMinX) <= positionTieTolerance,
                          candidate.displayStart < existing.displayStart {
                    firstByLine[candidate.lineIndex] = candidate
                }
            } else {
                firstByLine[candidate.lineIndex] = candidate
            }
        }

        let sortedLines = firstByLine.keys.sorted()
        var results: [LeftBoundaryLineResult] = []
        results.reserveCapacity(sortedLines.count)

        for lineIndex in sortedLines {
            guard let c = firstByLine[lineIndex] else { continue }
            let deltaX = c.envelopeMinX - leftGuideX
            let isDeviation = abs(deltaX) > alignedThreshold
            let direction: BoundaryDirection = {
                if isDeviation == false { return .ok }
                return deltaX < 0 ? .left : .right
            }()

            results.append(
                LeftBoundaryLineResult(
                    lineIndex: lineIndex,
                    tokenIndex: c.tokenIndex,
                    displayStart: c.displayStart,
                    tokenLeftX: c.envelopeMinX,
                    baseLeftX: c.baseMinX,
                    deltaX: deltaX,
                    direction: direction,
                    isDeviation: isDeviation,
                    snippet: c.snippet
                )
            )
        }

        return results
    }

    struct StartLineCandidate {
        let lineIndex: Int
        let tokenIndex: Int
        let startX: CGFloat
    }

    struct StartLineResult {
        let lineIndex: Int
        let tokenIndex: Int
        let startX: CGFloat
        let deltaX: CGFloat
    }

    static func evaluateStartLinesAgainstLeftGuide(
        candidates: [StartLineCandidate],
        targetLeftX: CGFloat
    ) -> [StartLineResult] {
        guard candidates.isEmpty == false else { return [] }

        var leftmostByLine: [Int: StartLineCandidate] = [:]
        leftmostByLine.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let existing = leftmostByLine[candidate.lineIndex] {
                if abs(candidate.startX - existing.startX) > positionTieTolerance {
                    if candidate.startX < existing.startX {
                        leftmostByLine[candidate.lineIndex] = candidate
                    }
                } else if candidate.tokenIndex < existing.tokenIndex {
                    leftmostByLine[candidate.lineIndex] = candidate
                }
            } else {
                leftmostByLine[candidate.lineIndex] = candidate
            }
        }

        let sortedLines = leftmostByLine.keys.sorted()
        var results: [StartLineResult] = []
        results.reserveCapacity(sortedLines.count)

        for lineIndex in sortedLines {
            guard let c = leftmostByLine[lineIndex] else { continue }
            results.append(
                StartLineResult(
                    lineIndex: lineIndex,
                    tokenIndex: c.tokenIndex,
                    startX: c.startX,
                    deltaX: c.startX - targetLeftX
                )
            )
        }

        return results
    }
}
