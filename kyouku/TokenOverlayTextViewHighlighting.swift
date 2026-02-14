import UIKit

extension TokenOverlayTextView {

    func baseHighlightRectsInContentCoordinates(in characterRange: NSRange) -> [CGRect] {
        guard let attributedText else { return [] }
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return [] }
        guard NSMaxRange(characterRange) <= attributedText.length else { return [] }

        guard #available(iOS 15.0, *) else { return [] }

        // Segment rects are in TextKit 2 coordinates; convert to content coordinates.
        // NOTE: Segment rects are locally clamped to their owning fragment's typographic line.
        return textKit2SegmentRectsInContentCoordinates(for: characterRange)
    }

    /// Like `baseHighlightRectsInContentCoordinates`, but excludes the U+FFFC spacer characters
    /// inserted for ruby-width padding.
    ///
    /// Those spacers are *layout-affecting* and can wrap across lines; including them can make
    /// a token highlight appear to cover large empty areas (sometimes spanning multiple lines).
    func baseHighlightRectsInContentCoordinatesExcludingRubySpacers(in characterRange: NSRange) -> [CGRect] {
        guard let attributedText else { return [] }
        guard characterRange.location != NSNotFound, characterRange.length > 0 else { return [] }
        guard NSMaxRange(characterRange) <= attributedText.length else { return [] }

        let s = attributedText.string as NSString
        let end = NSMaxRange(characterRange)
        let spacer: unichar = 0xFFFC

        var subranges: [NSRange] = []
        subranges.reserveCapacity(4)

        var runStart = characterRange.location
        var i = characterRange.location
        while i < end {
            if s.character(at: i) == spacer {
                if i > runStart {
                    subranges.append(NSRange(location: runStart, length: i - runStart))
                }
                runStart = i + 1
            }
            i += 1
        }
        if end > runStart {
            subranges.append(NSRange(location: runStart, length: end - runStart))
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(8)
        for r in subranges {
            rects.append(contentsOf: baseHighlightRectsInContentCoordinates(in: r))
        }
        return rects
    }

    func updateSelectionHighlightPath() {
        guard let range = selectionHighlightRange,
              range.location != NSNotFound,
              range.length > 0,
              let attributedLength = attributedText?.length,
              NSMaxRange(range) <= attributedLength,
              textRange(for: range) != nil else {
            baseHighlightLayer.path = nil
            rubyHighlightLayer.path = nil
            rubyEnvelopeDebugRubyRectsLayer.path = nil
            rubyEnvelopeDebugBaseUnionLayer.path = nil
            rubyEnvelopeDebugRubyUnionLayer.path = nil
            rubyEnvelopeDebugFinalUnionLayer.path = nil
            return
        }

        // 1) Collect base (headword) highlight rects in content coordinates.
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
        let baseRectsInContent: [CGRect] = {
            if #available(iOS 15.0, *) {
                let rects = baseHighlightRectsInContentCoordinatesExcludingRubySpacers(in: range)
                if rects.isEmpty == false { return rects }
            }

            // Fallback: selection rects are view-coordinate; convert to content-coordinate.
            let rectsInView = baseHighlightRects(in: range)
            guard rectsInView.isEmpty == false else { return [] }
            let offset = contentOffset
            return rectsInView.map { $0.offsetBy(dx: offset.x, dy: offset.y) }
        }()

        // 2) Union base rects per visual line.
        var highlightRectsInContent = unionRectsByLine(baseRectsInContent)
        let baseRectUnionInContent: CGRect = {
            var u = CGRect.null
            for r in highlightRectsInContent {
                u = u.isNull ? r : u.union(r)
            }
            return u
        }()

        // 3) Identify the selected token and fetch ruby rects from the overlay layers.
        let rubyHighlightTokenIndex: Int? = {
            let sourceLoc = sourceIndex(fromDisplayIndex: range.location)
            guard let (tokenIndex, _) = semanticSpans.spanContext(containingUTF16Index: sourceLoc) else { return nil }
            return tokenIndex
        }()

        let rubyRectsInContent: [CGRect] = {
            guard let rubyHighlightTokenIndex else { return [] }
            return rubyHighlightRectsInContentCoordinates(forTokenIndex: rubyHighlightTokenIndex)
        }()
        let rubyRectUnionInContent: CGRect = {
            var u = CGRect.null
            for r in rubyRectsInContent {
                u = u.isNull ? r : u.union(r)
            }
            return u
        }()

        // 4) Expand the highlight to enclose ruby + headword ("ruby envelope").
        if rubyRectUnionInContent.isNull == false {
            // Attach ruby bounds to the closest base line below it (or append if no good match).
            let rubyMaxY = rubyRectUnionInContent.maxY
            let maxSnapDistance = max(8, rubyHighlightHeadroom + 8)
            if let best = highlightRectsInContent.enumerated().min(by: { a, b in
                abs(a.element.minY - rubyMaxY) < abs(b.element.minY - rubyMaxY)
            }) {
                let dy = abs(best.element.minY - rubyMaxY)
                if dy <= maxSnapDistance {
                    highlightRectsInContent[best.offset] = highlightRectsInContent[best.offset].union(rubyRectUnionInContent)
                } else {
                    highlightRectsInContent.append(rubyRectUnionInContent)
                }
            } else {
                highlightRectsInContent = [rubyRectUnionInContent]
            }
        }

        let highlightRectPreInsets: CGRect = {
            var u = CGRect.null
            for r in highlightRectsInContent {
                u = u.isNull ? r : u.union(r)
            }
            return u
        }()

        guard highlightRectPreInsets.isNull == false, highlightRectPreInsets.isEmpty == false else {
            baseHighlightLayer.path = nil
            rubyHighlightLayer.path = nil
            return
        }

        // Keep highlight overlays attached to the same scrolling container as ruby overlays.
        highlightOverlayContainerLayer.frame = CGRect(origin: .zero, size: contentSize)

        if Self.verboseRubyLoggingEnabled {
            rubyEnvelopeDebugRubyRectsLayer.frame = highlightOverlayContainerLayer.bounds
            rubyEnvelopeDebugBaseUnionLayer.frame = highlightOverlayContainerLayer.bounds
            rubyEnvelopeDebugRubyUnionLayer.frame = highlightOverlayContainerLayer.bounds
            rubyEnvelopeDebugFinalUnionLayer.frame = highlightOverlayContainerLayer.bounds
        }

        // 5) Apply optional caller-provided insets to the final highlight rects.
        let insets = selectionHighlightInsets
        if insets != .zero {
            highlightRectsInContent = highlightRectsInContent.compactMap { r in
                var rr = r
                rr.origin.x += insets.left
                rr.origin.y += insets.top
                rr.size.width -= (insets.left + insets.right)
                rr.size.height -= (insets.top + insets.bottom)
                guard rr.isNull == false, rr.isEmpty == false, rr.width > 0, rr.height > 0 else { return nil }
                return rr
            }
        }

        let highlightRectFinal: CGRect = {
            var u = CGRect.null
            for r in highlightRectsInContent {
                u = u.isNull ? r : u.union(r)
            }
            return u
        }()

        if Self.verboseRubyLoggingEnabled {
            let tokenDesc = rubyHighlightTokenIndex.map(String.init) ?? "<none>"
            func rectString(_ rect: CGRect) -> String { NSCoder.string(for: rect) }
            print(
                "[RubyEnvelopeHighlight] token=\(tokenDesc) rubyRects=\(rubyRectsInContent.count) " +
                "baseUnion=\(rectString(baseRectUnionInContent)) " +
                "rubyUnion=\(rectString(rubyRectUnionInContent)) " +
                "finalPreInsets=\(rectString(highlightRectPreInsets)) " +
                "final=\(rectString(highlightRectFinal))"
            )

            // Draw ruby rects (green), base union (blue), ruby union (green), final union (red).
            let rubyRectsPath = CGMutablePath()
            for r in rubyRectsInContent {
                if r.isNull == false, r.isEmpty == false {
                    rubyRectsPath.addRect(r)
                }
            }
            rubyEnvelopeDebugRubyRectsLayer.path = rubyRectsPath.isEmpty ? nil : rubyRectsPath
            rubyEnvelopeDebugBaseUnionLayer.path = (baseRectUnionInContent.isNull || baseRectUnionInContent.isEmpty)
                ? nil
                : UIBezierPath(rect: baseRectUnionInContent).cgPath
            rubyEnvelopeDebugRubyUnionLayer.path = (rubyRectUnionInContent.isNull || rubyRectUnionInContent.isEmpty)
                ? nil
                : UIBezierPath(rect: rubyRectUnionInContent).cgPath
            rubyEnvelopeDebugFinalUnionLayer.path = (highlightRectFinal.isNull || highlightRectFinal.isEmpty)
                ? nil
                : UIBezierPath(rect: highlightRectFinal).cgPath
        } else {
            rubyEnvelopeDebugRubyRectsLayer.path = nil
            rubyEnvelopeDebugBaseUnionLayer.path = nil
            rubyEnvelopeDebugRubyUnionLayer.path = nil
            rubyEnvelopeDebugFinalUnionLayer.path = nil
        }

        // 6) Convert rects into a rounded-rect path and assign to the base highlight layer.
        let highlightPath = CGMutablePath()
        let highlightOutset: CGFloat = 1
        for r in highlightRectsInContent {
            let rr = r.insetBy(dx: -highlightOutset, dy: -highlightOutset)
            guard rr.isNull == false, rr.isEmpty == false, rr.width.isFinite, rr.height.isFinite else { continue }
            let radius = min(6, max(0, min(rr.width, rr.height) * 0.5))
            highlightPath.addPath(UIBezierPath(roundedRect: rr, cornerRadius: radius).cgPath)
        }
        baseHighlightLayer.path = highlightPath.isEmpty ? nil : highlightPath

        // Envelope highlight already includes ruby bounds.
        rubyHighlightLayer.path = nil
    }

    /// Debug overlay: draws selection-style envelope rectangles (ruby+headword union)
    /// for every semantic token.
    ///
    /// Controlled by the existing `RubyEnvelopeDebug.selectionEnvelopeRects` toggle.
    func updateRubyEnvelopeDebugTokenEnvelopesIfNeeded() {
        guard rubyEnvelopeDebugSelectionEnvelopeRectsEnabled else {
            rubyEnvelopeDebugSelectionEnvelopeRectsLayer.path = nil
            rubyEnvelopeDebugSelectionEnvelopeRectsLayer.isHidden = true
            return
        }

        guard attributedText != nil, semanticSpans.isEmpty == false else {
            rubyEnvelopeDebugSelectionEnvelopeRectsLayer.path = nil
            rubyEnvelopeDebugSelectionEnvelopeRectsLayer.isHidden = false
            return
        }

        rubyEnvelopeDebugSelectionEnvelopeRectsLayer.frame = highlightOverlayContainerLayer.bounds

        let path = CGMutablePath()
        let highlightOutset: CGFloat = 1
        let maxTokens = min(semanticSpans.count, 1024)
        let insets = selectionHighlightInsets

        for tokenIndex in 0..<maxTokens {
            let sourceRange = semanticSpans[tokenIndex].range
            guard sourceRange.location != NSNotFound, sourceRange.length > 0 else { continue }

            // Base rects for this token (in display coordinates) in content space.
            let display = displayRange(fromSourceRange: sourceRange)
            let baseRectsInContent = baseHighlightRectsInContentCoordinatesExcludingRubySpacers(in: display)
            guard baseRectsInContent.isEmpty == false else { continue }

            var tokenRectsInContent = unionRectsByLine(baseRectsInContent)

            // Ruby rect union for this token (from overlay layer frames).
            let rubyRects = rubyHighlightRectsInContentCoordinates(forTokenIndex: tokenIndex)
            let rubyUnion: CGRect = {
                var u = CGRect.null
                for r in rubyRects {
                    u = u.isNull ? r : u.union(r)
                }
                return u
            }()

            if rubyUnion.isNull == false {
                // Attach ruby bounds to the closest base line below it.
                let rubyMaxY = rubyUnion.maxY
                let maxSnapDistance = max(8, rubyHighlightHeadroom + 8)
                if let best = tokenRectsInContent.enumerated().min(by: { a, b in
                    abs(a.element.minY - rubyMaxY) < abs(b.element.minY - rubyMaxY)
                }) {
                    let dy = abs(best.element.minY - rubyMaxY)
                    if dy <= maxSnapDistance {
                        tokenRectsInContent[best.offset] = tokenRectsInContent[best.offset].union(rubyUnion)
                    } else {
                        tokenRectsInContent.append(rubyUnion)
                    }
                } else {
                    tokenRectsInContent = [rubyUnion]
                }
            }

            if insets != .zero {
                tokenRectsInContent = tokenRectsInContent.compactMap { r in
                    var rr = r
                    rr.origin.x += insets.left
                    rr.origin.y += insets.top
                    rr.size.width -= (insets.left + insets.right)
                    rr.size.height -= (insets.top + insets.bottom)
                    guard rr.isNull == false, rr.isEmpty == false, rr.width > 0, rr.height > 0 else { return nil }
                    return rr
                }
            }

            for r in tokenRectsInContent {
                let rr = r.insetBy(dx: -highlightOutset, dy: -highlightOutset)
                guard rr.isNull == false, rr.isEmpty == false, rr.width.isFinite, rr.height.isFinite else { continue }
                path.addRect(rr)
            }
        }

        rubyEnvelopeDebugSelectionEnvelopeRectsLayer.path = path.isEmpty ? nil : path
        rubyEnvelopeDebugSelectionEnvelopeRectsLayer.isHidden = false
    }

    func baseHighlightRects(in characterRange: NSRange) -> [CGRect] {
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

    func rubyHighlightRectsInContentCoordinates(forTokenIndex tokenIndex: Int) -> [CGRect] {
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

}
