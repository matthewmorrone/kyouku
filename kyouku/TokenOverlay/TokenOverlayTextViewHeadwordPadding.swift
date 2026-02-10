import UIKit
import CoreText
import ObjectiveC

extension TokenOverlayTextView {
    // MARK: - Three-pass headword padding correction (performance-sensitive)

    // Required algorithm phases (in order):
    // 1) Compute preferred centers for base text and ruby.
    // 2) Resolve ruby–ruby overlaps by inserting horizontal space BETWEEN headwords only.
    //    (We implement this as additional `.kern` on the trailing edge of the preceding headword.)
    // 3) After (2), for each visual line, enforce the left boundary by shifting the whole line
    //    right via a leading line-padding spacer. This is NOT per-token padding.
    @available(iOS 15.0, *)
    private var lineStartBoundaryCorrectionScheduled: Bool {
        get { objc_getAssociatedObject(self, &AssociatedKeys.lineStartBoundaryCorrectionScheduled) as? Bool ?? false }
        set { objc_setAssociatedObject(self, &AssociatedKeys.lineStartBoundaryCorrectionScheduled, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    @available(iOS 15.0, *)
    private var lastLineStartBoundaryCorrectionSignature: Int {
        get { objc_getAssociatedObject(self, &AssociatedKeys.lastLineStartBoundaryCorrectionSignature) as? Int ?? 0 }
        set { objc_setAssociatedObject(self, &AssociatedKeys.lastLineStartBoundaryCorrectionSignature, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private enum AssociatedKeys {
        static var lineStartBoundaryCorrectionScheduled: UInt8 = 0
        static var lastLineStartBoundaryCorrectionSignature: UInt8 = 0
    }

    @available(iOS 15.0, *)
    private struct VisibleLineInfo {
        let characterRange: NSRange
        let typographicRectInContent: CGRect
    }

    @available(iOS 15.0, *)
    private func textKit2VisibleLineInfos() -> [VisibleLineInfo] {
        guard let tlm = textLayoutManager else { return [] }

        let inset = textContainerInset
        let offset = contentOffset

        let extraY = max(16, rubyHighlightHeadroom + 12)
        let viewBounds = CGRect(origin: .zero, size: bounds.size)
        let visibleRectInView = viewBounds.insetBy(dx: -4, dy: -extraY)

        var lines: [VisibleLineInfo] = []
        lines.reserveCapacity(64)

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
                if viewRect.isNull || viewRect.isEmpty { continue }
                if viewRect.intersects(visibleRectInView) == false { continue }

                let cr = line.characterRange
                if cr.location == NSNotFound || cr.length <= 0 { continue }

                let contentRect = CGRect(
                    x: r.origin.x + origin.x + inset.left,
                    y: r.origin.y + origin.y + inset.top,
                    width: r.size.width,
                    height: r.size.height
                )
                lines.append(.init(characterRange: cr, typographicRectInContent: contentRect))
            }
            return true
        }

        // Dedup/normalize: keep stable ordering by Y then X.
        let unique = Array(Set(lines.map { $0.characterRange.location })).sorted()
        if unique.count == lines.count {
            return lines.sorted { a, b in
                if abs(a.typographicRectInContent.minY - b.typographicRectInContent.minY) > 0.5 {
                    return a.typographicRectInContent.minY < b.typographicRectInContent.minY
                }
                return a.typographicRectInContent.minX < b.typographicRectInContent.minX
            }
        }

        var byStart: [Int: VisibleLineInfo] = [:]
        byStart.reserveCapacity(lines.count)
        for l in lines {
            // Keep the first seen entry for a start index.
            if byStart[l.characterRange.location] == nil {
                byStart[l.characterRange.location] = l
            }
        }
        return unique.compactMap { byStart[$0] }
    }

    @available(iOS 15.0, *)
    func scheduleLineStartBoundaryCorrectionIfNeeded() {
        guard padHeadwordSpacing else { return }
        guard wrapLines else { return }
        guard lineStartBoundaryCorrectionScheduled == false else { return }
        guard let attributedText, attributedText.length > 0 else { return }
        guard cachedRubyRuns.isEmpty == false else { return }
        guard textLayoutManager != nil else { return }

        var hasher = Hasher()
        hasher.combine(attributedText.length)
        hasher.combine(attributedTextRevision)
        hasher.combine(cachedRubyRuns.count)
        hasher.combine(Int((textContainerInset.left * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainerInset.right * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainer.size.width * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainer.lineFragmentPadding * 10).rounded(.toNearestOrEven)))
        // Include any existing insertions so we can converge once stable.
        hasher.combine(rubyIndexMap.insertionPositions.count)
        let signature = hasher.finalize()
        guard signature != lastLineStartBoundaryCorrectionSignature else { return }

        guard let adjusted = lineStartBoundaryCorrectedTextIfNeeded(from: attributedText) else {
            lastLineStartBoundaryCorrectionSignature = signature
            return
        }

        lineStartBoundaryCorrectionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lineStartBoundaryCorrectionScheduled = false
            self.lastLineStartBoundaryCorrectionSignature = signature
            // Keep SOURCE↔DISPLAY mapping accurate if we inserted any display-only padding.
            self.rubyIndexMap = adjusted.indexMap
            self.applyAttributedText(adjusted.text)
        }
    }

    @available(iOS 15.0, *)
    private func lineStartBoundaryCorrectedTextIfNeeded(from text: NSAttributedString) -> (text: NSAttributedString, indexMap: RubyIndexMap)? {
        guard textLayoutManager != nil else { return nil }
        guard text.length > 0 else { return nil }

        // Visible lines only: TextKit 2 may not have full-document layout, and we want this
        // to stay cheap on long documents. As the user scrolls, additional lines get corrected.
        let visibleLines = textKit2VisibleLineInfos()
        guard visibleLines.isEmpty == false else { return nil }

        let lineRectsInContent = visibleLines.map { $0.typographicRectInContent }

        // Fixed left boundary for a line in CONTENT coordinates (independent of any glyphs/spacers).
        let lineContentMinX = textContainerInset.left + textContainer.lineFragmentPadding

        let mutable = NSMutableAttributedString(attributedString: text)
        let backing = mutable.string as NSString

        func readKern(at index: Int) -> CGFloat {
            guard index >= 0, index < mutable.length else { return 0 }
            let v = mutable.attribute(.kern, at: index, effectiveRange: nil)
            if let num = v as? NSNumber { return CGFloat(num.doubleValue) }
            if let cg = v as? CGFloat { return cg }
            if let dbl = v as? Double { return CGFloat(dbl) }
            return 0
        }

        func addKern(_ extra: CGFloat, afterInkRange inkRange: NSRange) {
            guard extra.isFinite, extra > 0.01 else { return }
            guard inkRange.location != NSNotFound, inkRange.length > 0 else { return }
            guard NSMaxRange(inkRange) <= mutable.length else { return }
            let last = max(inkRange.location, NSMaxRange(inkRange) - 1)
            guard last >= 0, last < backing.length else { return }
            let composed = backing.rangeOfComposedCharacterSequence(at: last)
            guard composed.location != NSNotFound, composed.length > 0 else { return }
            let current = readKern(at: composed.location)
            mutable.addAttribute(.kern, value: current + extra, range: composed)
        }

        func isNonRubySpacer(at index: Int) -> Bool {
            guard index >= 0, index < mutable.length else { return false }
            if mutable.attribute(kCTRunDelegateAttributeName as NSAttributedString.Key, at: index, effectiveRange: nil) == nil {
                return false
            }
            if mutable.attribute(.furiganaReadingText, at: index, effectiveRange: nil) != nil {
                return false
            }
            if backing.length > 0, index < backing.length {
                return backing.character(at: index) == 0xFFFC
            }
            return true
        }

        func spacerWidth(at index: Int) -> CGFloat {
            guard index >= 0, index < mutable.length else { return 0 }
            guard let delegate = mutable.attribute(kCTRunDelegateAttributeName as NSAttributedString.Key, at: index, effectiveRange: nil) else { return 0 }
            let runDelegate = delegate as! CTRunDelegate
            let ref = CTRunDelegateGetRefCon(runDelegate)
            let num = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
            let v = CGFloat(num.doubleValue)
            return v.isFinite ? v : 0
        }

        func setSpacerWidth(_ width: CGFloat, at index: Int) {
            guard index >= 0, index < mutable.length else { return }
            let w = width.isFinite ? max(0, width) : 0
            var callbacks = CTRunDelegateCallbacks(
                version: kCTRunDelegateVersion1,
                dealloc: { ref in
                    Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).release()
                },
                getAscent: { _ in 0 },
                getDescent: { _ in 0 },
                getWidth: { ref in
                    let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                    let w = CGFloat(data.doubleValue)
                    return w.isFinite ? w : 0
                }
            )
            let boxed = NSNumber(value: Double(w))
            let ref = Unmanaged.passRetained(boxed).toOpaque()
            let delegate = CTRunDelegateCreate(&callbacks, ref)
            mutable.addAttribute(kCTRunDelegateAttributeName as NSAttributedString.Key, value: delegate as Any, range: NSRange(location: index, length: 1))
            mutable.addAttribute(.foregroundColor, value: UIColor.clear, range: NSRange(location: index, length: 1))
            mutable.addAttribute(kCTForegroundColorAttributeName as NSAttributedString.Key, value: UIColor.clear.cgColor, range: NSRange(location: index, length: 1))
        }

        func makeLinePaddingSpacer(width: CGFloat, sampleAttributesFrom displayIndex: Int) -> NSAttributedString {
            let attachmentChar = "\u{FFFC}"

            var callbacks = CTRunDelegateCallbacks(
                version: kCTRunDelegateVersion1,
                dealloc: { ref in
                    Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).release()
                },
                getAscent: { _ in 0 },
                getDescent: { _ in 0 },
                getWidth: { ref in
                    let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                    let w = CGFloat(data.doubleValue)
                    return w.isFinite ? w : 0
                }
            )
            let boxed = NSNumber(value: Double(max(0, width)))
            let ref = Unmanaged.passRetained(boxed).toOpaque()
            let delegate = CTRunDelegateCreate(&callbacks, ref)

            let baseFont = self.font ?? UIFont.systemFont(ofSize: 17)
            let insert = NSMutableAttributedString(
                string: attachmentChar,
                attributes: [
                    kCTRunDelegateAttributeName as NSAttributedString.Key: delegate as Any,
                    .foregroundColor: UIColor.clear,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: UIColor.clear.cgColor,
                    .font: baseFont
                ]
            )

            let idx = max(0, min(mutable.length - 1, displayIndex))
            if idx >= 0, idx < mutable.length {
                if let paragraph = mutable.attribute(.paragraphStyle, at: idx, effectiveRange: nil) {
                    insert.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: insert.length))
                }
                // Preserve any baselineOffset so the spacer behaves like surrounding text.
                if let baseline = mutable.attribute(.baselineOffset, at: idx, effectiveRange: nil) {
                    insert.addAttribute(.baselineOffset, value: baseline, range: NSRange(location: 0, length: insert.length))
                }
            }
            return insert
        }

        // Phase 1) Compute preferred ruby frames (unclamped) and associate them with visible lines.
        struct Proposal {
            let lineIndex: Int
            let run: RubyRun
            let baseFrame: CGRect
            let frame: CGRect
        }

        // Snapshot the authoritative resolved frames that were actually rendered.
        // This keeps pass (3) decisions/logging consistent with on-screen ruby.
        let resolvedRubyFramesByRunStart = rubyResolvedFramesByRunStart

        var proposalsByLine: [Int: [Proposal]] = [:]
        proposalsByLine.reserveCapacity(visibleLines.count)

        for run in cachedRubyRuns {
            let baseRectsInContent = textKit2AnchorRectsInContentCoordinates(for: run.inkRange, lineRectsInContent: lineRectsInContent)
            guard baseRectsInContent.isEmpty == false else { continue }
            let unionsInContent = unionRectsByLine(baseRectsInContent)
            guard unionsInContent.isEmpty == false else { continue }
            let baseUnionInContent = unionsInContent[0]
            guard let lineIndex = bestMatchingLineIndex(for: baseUnionInContent, candidates: lineRectsInContent) else { continue }
            guard lineIndex >= 0, lineIndex < lineRectsInContent.count else { continue }
            guard baseUnionInContent.intersects(lineRectsInContent[lineIndex]) else { continue }

            let rubyPointSize = max(1.0, run.fontSize)
            let rubyFont = (self.font ?? UIFont.systemFont(ofSize: rubyPointSize)).withSize(rubyPointSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: rubyFont,
                .foregroundColor: run.color
            ]
            let size = FuriganaText.measureTypographicSize(NSAttributedString(string: run.reading, attributes: attrs))
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { continue }

            let xUnclamped: CGFloat = {
                if let xr = caretXRangeInContentCoordinates(for: run.inkRange) {
                    switch furiganaHorizontalAlignment {
                    case .leading:
                        return xr.startX
                    case .center:
                        let baseWidth = max(0, xr.endX - xr.startX)
                        return xr.startX + ((baseWidth - size.width) / 2.0)
                    }
                }
                switch furiganaHorizontalAlignment {
                case .leading:
                    return baseUnionInContent.minX
                case .center:
                    return baseUnionInContent.midX - (size.width / 2.0)
                }
            }()

            let y = baseUnionInContent.minY - size.height
            let frame = CGRect(x: xUnclamped, y: y, width: size.width, height: size.height)
            proposalsByLine[lineIndex, default: []].append(.init(lineIndex: lineIndex, run: run, baseFrame: baseUnionInContent, frame: frame))
        }

        guard proposalsByLine.isEmpty == false else { return nil }

        var didChange = false
        var didKernChange = false

        // Phase 2) Resolve ruby–ruby overlaps by inserting horizontal space BETWEEN headwords only.
        // We implement this by increasing `.kern` after the preceding headword's last visible glyph.
        var adjustedFramesByRunStart: [Int: CGRect] = [:]
        adjustedFramesByRunStart.reserveCapacity(256)

        let minGap: CGFloat = 0.5

        for (lineIndex, proposals) in proposalsByLine {
            let sorted = proposals.sorted { a, b in
                if abs(a.frame.minX - b.frame.minX) > 0.5 { return a.frame.minX < b.frame.minX }
                return a.run.inkRange.location < b.run.inkRange.location
            }

            var cumulativeShift: CGFloat = 0
            var prevAdjusted: CGRect? = nil
            var prevRun: RubyRun? = nil

            for p in sorted {
                var adjusted = p.frame
                adjusted.origin.x += cumulativeShift

                if let prev = prevAdjusted, let prevRun {
                    let requiredMinX = prev.maxX + minGap
                    if adjusted.minX < requiredMinX {
                        let shift = requiredMinX - adjusted.minX
                        // Space goes BETWEEN headwords: add after the previous headword.
                        addKern(shift, afterInkRange: prevRun.inkRange)
                        didKernChange = true
                        cumulativeShift += shift
                        adjusted.origin.x += shift
                        didChange = true
                    }
                }

                adjustedFramesByRunStart[p.run.inkRange.location] = adjusted
                prevAdjusted = adjusted
                prevRun = p.run
            }

            _ = lineIndex
        }

        // If phase (2) changed `.kern`, the final rendered ruby frames will be re-centered
        // during the next layout pass. Do not run phase (3) against stale frames; instead,
        // apply the kern changes now and let phase (3) run on the next invocation.
        if didKernChange {
            return (mutable, rubyIndexMap)
        }

        // Phase 3) After phase (2), for each visual line, enforce the left boundary.
        // If the first headword's ruby would overhang, shift the WHOLE line right by inserting
        // a leading line-padding spacer (not per-token padding).
        struct LineInsertion {
            let displayIndex: Int
            let width: CGFloat
            let sourceInsertionPosition: Int
        }
        var lineInsertions: [LineInsertion] = []
        lineInsertions.reserveCapacity(16)

        for (lineIndex, proposals) in proposalsByLine {
            guard lineIndex >= 0, lineIndex < visibleLines.count else { continue }
            let line = visibleLines[lineIndex]
            let startIndex = line.characterRange.location
            guard startIndex != NSNotFound else { continue }

            let lineRect = lineRectsInContent[lineIndex]

            // Find the authoritative first headword on this line: choose the headword whose BASE
            // frame has the smallest minX among those that intersect this line fragment.
            var best: (run: RubyRun, rubyFrame: CGRect, baseFrame: CGRect)? = nil
            for p in proposals {
                guard p.baseFrame.intersects(lineRect) else { continue }
                let rubyFrame = resolvedRubyFramesByRunStart[p.run.inkRange.location]
                    ?? adjustedFramesByRunStart[p.run.inkRange.location]
                    ?? p.frame
                if let cur = best {
                    if p.baseFrame.minX < (cur.baseFrame.minX - 0.5) {
                        best = (p.run, rubyFrame, p.baseFrame)
                    } else if abs(p.baseFrame.minX - cur.baseFrame.minX) <= 0.5 {
                        // Stable tiebreak: earlier in document wins.
                        if p.run.inkRange.location < cur.run.inkRange.location {
                            best = (p.run, rubyFrame, p.baseFrame)
                        }
                    }
                } else {
                    best = (p.run, rubyFrame, p.baseFrame)
                }
            }
            guard let first = best else { continue }

            let firstTokenIndex: Int = {
                // Derive a stable token index for logging only.
                guard semanticSpans.isEmpty == false else { return 0 }
                let firstSourceRange = sourceRange(fromDisplayRange: first.run.inkRange)
                let loc = max(0, firstSourceRange.location == NSNotFound ? 0 : firstSourceRange.location)

                // Binary search for the last span whose start <= loc.
                var low = 0
                var high = semanticSpans.count
                while low < high {
                    let mid = (low + high) / 2
                    if semanticSpans[mid].range.location <= loc {
                        low = mid + 1
                    } else {
                        high = mid
                    }
                }
                let idx = max(0, min(semanticSpans.count - 1, low - 1))
                if NSLocationInRange(loc, semanticSpans[idx].range) { return idx }
                if idx + 1 < semanticSpans.count, NSLocationInRange(loc, semanticSpans[idx + 1].range) { return idx + 1 }
                return idx
            }()
            let debugDelta = lineContentMinX - first.rubyFrame.minX
            print(String(format: "[LineStartBoundary] line=%d firstToken=%d lineContentMinX=%.2f rubyMinX=%.2f delta=%.2f", lineIndex, firstTokenIndex, lineContentMinX, first.rubyFrame.minX, debugDelta))

            if first.rubyFrame.minX < (lineContentMinX - 0.5) {
                let delta = lineContentMinX - first.rubyFrame.minX
                guard delta.isFinite, delta > 0.5 else { continue }

                // If a non-ruby spacer already exists at the line start, grow it.
                if isNonRubySpacer(at: startIndex) {
                    let existing = spacerWidth(at: startIndex)
                    setSpacerWidth(existing + delta, at: startIndex)
                    didChange = true
                } else {
                    // Insert a line-padding spacer at the visual line start.
                    let s = sourceIndex(fromDisplayIndex: startIndex)
                    lineInsertions.append(.init(displayIndex: startIndex, width: delta, sourceInsertionPosition: s))
                    didChange = true
                }
            }
        }

        if lineInsertions.isEmpty == false {
            // Apply insertions from end → start to keep indices stable.
            let sorted = lineInsertions.sorted { a, b in
                if a.displayIndex != b.displayIndex { return a.displayIndex > b.displayIndex }
                return a.width > b.width
            }
            for ins in sorted {
                let insert = makeLinePaddingSpacer(width: ins.width, sampleAttributesFrom: ins.displayIndex)
                let safeIndex = max(0, min(mutable.length, ins.displayIndex))
                mutable.insert(insert, at: safeIndex)
            }

            // Update index map so selection/semantic spans remain in SOURCE coordinates.
            var newPositions = rubyIndexMap.insertionPositions
            newPositions.append(contentsOf: lineInsertions.map { $0.sourceInsertionPosition })
            newPositions.sort()
            let newMap = RubyIndexMap(insertionPositions: newPositions)
            return (mutable, newMap)
        }

        return didChange ? (mutable, rubyIndexMap) : nil
    }

    func caretXRangeInViewCoordinates(for characterRange: NSRange) -> (startX: CGFloat, endX: CGFloat)? {
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

    func caretXRangeInContentCoordinates(for characterRange: NSRange) -> (startX: CGFloat, endX: CGFloat)? {
        guard let xr = caretXRangeInViewCoordinates(for: characterRange) else { return nil }
        // Convert view → content coordinates for scroll-view overlay layers.
        return (startX: xr.startX + contentOffset.x, endX: xr.endX + contentOffset.x)
    }
}
