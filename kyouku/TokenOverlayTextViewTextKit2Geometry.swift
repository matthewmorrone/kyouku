import UIKit

extension TokenOverlayTextView {

    func textKit2AnchorRectsInContentCoordinates(for characterRange: NSRange, lineRectsInContent: [CGRect]) -> [CGRect] {
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

    func textKit2LineTypographicRectsInContentCoordinates(visibleOnly: Bool = false) -> [CGRect] {
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

    @available(iOS 15.0, *)
    func textKit2SegmentRectsInViewCoordinates(for characterRange: NSRange) -> [CGRect] {
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

            // IMPORTANT: Preserve invariant: segment rects must never span multiple lines.
            // Split by typographic line rects when possible.
            if let frag, picked.isNull == false, picked.isEmpty == false {
                #if DEBUG
                // If a segment overlaps more than one typographic line, fail fast.
                // This should never happen after normalization/clamping.
                let minInterHeight: CGFloat = 0.5
                var intersectionCount = 0
                for line in frag.textLineFragments {
                    let lb = line.typographicBounds
                    let lineRect = CGRect(
                        x: lb.origin.x + fragOrigin.x + inset.left - offset.x,
                        y: lb.origin.y + fragOrigin.y + inset.top - offset.y,
                        width: lb.size.width,
                        height: lb.size.height
                    )
                    let inter = picked.intersection(lineRect)
                    if inter.isNull == false, inter.isEmpty == false, inter.height >= minInterHeight {
                        intersectionCount += 1
                        if intersectionCount > 1 { break }
                    }
                }
                precondition(intersectionCount == 1, "TextKit2 segment rect crosses line boundary (view coords). picked=\(NSCoder.string(for: picked)) intersections=\(intersectionCount) range=\(NSStringFromRange(characterRange))")
                #endif

                var didSplit = false
                for line in frag.textLineFragments {
                    let lb = line.typographicBounds
                    let lineRect = CGRect(
                        x: lb.origin.x + fragOrigin.x + inset.left - offset.x,
                        y: lb.origin.y + fragOrigin.y + inset.top - offset.y,
                        width: lb.size.width,
                        height: lb.size.height
                    )
                    let inter = picked.intersection(lineRect)
                    guard inter.isNull == false, inter.isEmpty == false else { continue }
                    var out = inter
                    out.origin.y = lineRect.minY
                    out.size.height = lineRect.height
                    guard out.isNull == false, out.isEmpty == false, out.width.isFinite, out.height.isFinite else { continue }
                    rects.append(out)
                    didSplit = true
                }

                #if DEBUG
                precondition(didSplit, "TextKit2 segment rect did not intersect any typographic line (view coords). picked=\(NSCoder.string(for: picked)) range=\(NSStringFromRange(characterRange))")
                #endif

                if didSplit == false {
                    rects.append(picked)
                }
            } else if picked.isNull == false, picked.isEmpty == false {
                #if DEBUG
                precondition(frag != nil, "TextKit2 segment has no owning layout fragment (view coords). range=\(NSStringFromRange(characterRange)) rect=\(NSCoder.string(for: picked))")
                #endif
                rects.append(picked)
            }
            return true
        }

        return rects
    }

    @available(iOS 15.0, *)
    func textKit2SegmentRectsInContentCoordinates(for characterRange: NSRange) -> [CGRect] {
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

            // IMPORTANT: Preserve invariant: segment rects must never span multiple lines.
            // Split by typographic line rects when possible.
            if let frag, picked.isNull == false, picked.isEmpty == false {
                #if DEBUG
                // If a segment overlaps more than one typographic line, fail fast.
                // This should never happen after normalization/clamping.
                let minInterHeight: CGFloat = 0.5
                var intersectionCount = 0
                for line in frag.textLineFragments {
                    let lb = line.typographicBounds
                    let lineRect = CGRect(
                        x: lb.origin.x + fragOrigin.x + inset.left,
                        y: lb.origin.y + fragOrigin.y + inset.top,
                        width: lb.size.width,
                        height: lb.size.height
                    )
                    let inter = picked.intersection(lineRect)
                    if inter.isNull == false, inter.isEmpty == false, inter.height >= minInterHeight {
                        intersectionCount += 1
                        if intersectionCount > 1 { break }
                    }
                }
                precondition(intersectionCount == 1, "TextKit2 segment rect crosses line boundary (content coords). picked=\(NSCoder.string(for: picked)) intersections=\(intersectionCount) range=\(NSStringFromRange(characterRange))")
                #endif

                var didSplit = false
                for line in frag.textLineFragments {
                    let lb = line.typographicBounds
                    let lineRect = CGRect(
                        x: lb.origin.x + fragOrigin.x + inset.left,
                        y: lb.origin.y + fragOrigin.y + inset.top,
                        width: lb.size.width,
                        height: lb.size.height
                    )
                    let inter = picked.intersection(lineRect)
                    guard inter.isNull == false, inter.isEmpty == false else { continue }
                    var out = inter
                    out.origin.y = lineRect.minY
                    out.size.height = lineRect.height
                    guard out.isNull == false, out.isEmpty == false, out.width.isFinite, out.height.isFinite else { continue }
                    rects.append(out)
                    didSplit = true
                }

                #if DEBUG
                precondition(didSplit, "TextKit2 segment rect did not intersect any typographic line (content coords). picked=\(NSCoder.string(for: picked)) range=\(NSStringFromRange(characterRange))")
                #endif

                if didSplit == false {
                    rects.append(picked)
                }
            } else if picked.isNull == false, picked.isEmpty == false {
                #if DEBUG
                precondition(frag != nil, "TextKit2 segment has no owning layout fragment (content coords). range=\(NSStringFromRange(characterRange)) rect=\(NSCoder.string(for: picked))")
                #endif
                rects.append(picked)
            }
            return true
        }

        return rects
    }

    func visibleUTF16Range() -> NSRange? {
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

    func expandRange(_ range: NSRange, by delta: Int) -> NSRange {
        guard let attributedText else { return range }
        let maxLen = attributedText.length
        guard maxLen > 0 else { return range }

        let start = max(0, range.location - delta)
        let end = min(maxLen, NSMaxRange(range) + delta)
        guard end > start else { return range }
        return NSRange(location: start, length: end - start)
    }

    func unionRectsByLine(_ rects: [CGRect]) -> [CGRect] {
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

}
