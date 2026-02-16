import UIKit

extension TokenOverlayTextView {
    // MARK: - Line rect helpers (inspection + spacing)

    func textKit2LineTypographicRectsInViewCoordinates(visibleOnly: Bool) -> [CGRect] {
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

    func bestMatchingLineIndex(for rect: CGRect, candidates: [CGRect]) -> Int? {
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

    func bestMatchingLineRect(for rect: CGRect, candidates: [CGRect]) -> CGRect? {
        guard let idx = bestMatchingLineIndex(for: rect, candidates: candidates) else { return nil }
        return candidates[idx]
    }

    func textRange(for nsRange: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: nsRange.location),
              let end = position(from: start, offset: nsRange.length) else {
            return nil
        }
        return textRange(from: start, to: end)
    }

    // MARK: - Gesture installation

    func updateInspectionGestureState() {
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

    func updateTokenSpacingGestureState() {
        let wantsEnabled = (tokenSpacingChangedHandler != nil && tokenSpacingValueProvider != nil)
        let alreadyAdded = gestureRecognizers?.contains(where: { $0 === tokenSpacingPanRecognizer }) ?? false

        // Disable spacing drag when drag-selection is enabled or when we're in character-tap mode.
        let allow = wantsEnabled && isDragSelectionEnabled == false && characterTapHandler == nil

        if allow {
            if alreadyAdded == false {
                addGestureRecognizer(tokenSpacingPanRecognizer)
            }
        } else {
            if alreadyAdded {
                removeGestureRecognizer(tokenSpacingPanRecognizer)
            }
            tokenSpacingActiveBoundaryUTF16 = nil
            tokenSpacingStartValue = 0
        }
    }

    func updateDragSelectionGestureState() {
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

        // Drag-selection and spacing-drag are mutually exclusive.
        updateTokenSpacingGestureState()
    }

    // MARK: - Gesture logic

    func shouldBeginTokenSpacingPan() -> Bool {
        guard isTapInspectionEnabled else { return false }
        guard tokenSpacingValueProvider != nil, tokenSpacingChangedHandler != nil else { return false }
        guard isDragSelectionEnabled == false else { return false }
        guard characterTapHandler == nil else { return false }

        let pan = tokenSpacingPanRecognizer
        let velocity = pan.velocity(in: self)
        // Only begin if the gesture is primarily horizontal.
        // Be permissive here so slow/short drags still work.
        guard abs(velocity.x) >= abs(velocity.y) * 1.05 else { return false }

        let point = pan.location(in: self)
        guard let rawIndex = utf16IndexForTap(at: point),
              let resolvedIndex = resolvedTextIndex(from: rawIndex) else { return false }
        let sourceIndex = sourceIndex(fromDisplayIndex: resolvedIndex)
        guard let selection = spanSelectionContext(forUTF16Index: sourceIndex) else { return false }
        guard pointHitsSemanticSpanForSpacing(selection, at: point) else { return false }
        let backing = debugSourceText ?? (attributedText.string as NSString)
        let length = backing.length
        guard length > 0 else { return false }

        // Prefer the boundary that already has spacing (so you can decrease it),
        // otherwise default to the leading boundary so the touched token moves.
        guard let boundary = TokenSpacingInvariantSource.resolveTokenSpacingBoundary(
            selection: selection,
            length: length,
            backing: backing,
            currentWidthProvider: tokenSpacingValueProvider
        ) else {
            return false
        }
        // Ensure the boundary is valid for persistence.
        guard boundary > 0, boundary < length else { return false }
        return true
    }

    @objc
    func handleTokenSpacingPan(_ recognizer: UIPanGestureRecognizer) {
        guard tokenSpacingValueProvider != nil, let tokenSpacingChangedHandler else { return }
        guard characterTapHandler == nil else { return }
        guard isDragSelectionEnabled == false else { return }
        let backing = debugSourceText ?? (attributedText.string as NSString)
        let length = backing.length
        guard length > 0 else { return }

        let point = recognizer.location(in: self)

        func resolveBoundary(at point: CGPoint) -> Int? {
            guard let rawIndex = utf16IndexForTap(at: point),
                  let resolvedIndex = resolvedTextIndex(from: rawIndex) else { return nil }
            let sourceIndex = sourceIndex(fromDisplayIndex: resolvedIndex)
            guard let selection = spanSelectionContext(forUTF16Index: sourceIndex) else { return nil }
            guard pointHitsSemanticSpanForSpacing(selection, at: point) else { return nil }
            return TokenSpacingInvariantSource.resolveTokenSpacingBoundary(
                selection: selection,
                length: length,
                backing: backing,
                currentWidthProvider: tokenSpacingValueProvider
            )
        }

        switch recognizer.state {
        case .began:
            guard let boundary = resolveBoundary(at: point) else {
                tokenSpacingActiveBoundaryUTF16 = nil
                tokenSpacingStartValue = 0
                return
            }
            tokenSpacingActiveBoundaryUTF16 = boundary
            tokenSpacingStartValue = tokenSpacingValueProvider?(boundary) ?? 0
            TokenSpacingInvariantSource.logSpacingTelemetry(
                String(
                    format: "drag-begin boundary=%d start=%.2f",
                    boundary,
                    tokenSpacingStartValue
                )
            )

        case .changed:
            guard let boundary = tokenSpacingActiveBoundaryUTF16 else { return }
            let delta = recognizer.translation(in: self).x
            let proposed = tokenSpacingStartValue + delta
            let clamped = TokenSpacingInvariantSource.clampTokenSpacingWidth(proposed)
            tokenSpacingChangedHandler(boundary, clamped, false)

        case .ended:
            guard let boundary = tokenSpacingActiveBoundaryUTF16 else { return }
            let delta = recognizer.translation(in: self).x
            let proposed = tokenSpacingStartValue + delta
            let clamped = TokenSpacingInvariantSource.clampTokenSpacingWidth(proposed)
            tokenSpacingChangedHandler(boundary, clamped, true)
            TokenSpacingInvariantSource.logSpacingTelemetry(
                String(
                    format: "drag-end boundary=%d start=%.2f delta=%.2f proposed=%.2f clamped=%.2f",
                    boundary,
                    tokenSpacingStartValue,
                    delta,
                    proposed,
                    clamped
                )
            )
            tokenSpacingActiveBoundaryUTF16 = nil
            tokenSpacingStartValue = 0

        case .cancelled, .failed:
            tokenSpacingActiveBoundaryUTF16 = nil
            tokenSpacingStartValue = 0

        default:
            break
        }
    }

    @objc
    func handleDragSelectionLongPress(_ recognizer: UILongPressGestureRecognizer) {
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

            let selectedLength: Int = Swift.max(0, end - start)
            let selected = NSRange(location: start, length: selectedLength)
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
    /// Tap → resolve semantic span (source) → hit-test → highlight its display range.
    func handleInspectionTap(_ recognizer: UITapGestureRecognizer) {
        guard isTapInspectionEnabled, recognizer.state == .ended else { return }

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

    /// Composed-character range in the DISPLAY string at a UTF-16 index.
    func composedCharacterRangeInDisplayString(atUTF16Index index: Int) -> NSRange {
        guard let text = attributedText?.string, text.isEmpty == false else { return NSRange(location: NSNotFound, length: 0) }
        let ns = text as NSString
        guard index >= 0, index < ns.length else { return NSRange(location: NSNotFound, length: 0) }
        return ns.rangeOfComposedCharacterSequence(at: index)
    }

    /// Hit-test a DISPLAY range against base glyphs or ruby overlay glyphs.
    func pointHitsDisplayRange(_ range: NSRange, at point: CGPoint) -> Bool {
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

    /// Hit-test a semantic span's rendered glyphs (base or ruby).
    func pointHitsSemanticSpan(_ selection: RubySpanSelection, at point: CGPoint) -> Bool {
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

    func pointHitsSemanticSpanForSpacing(_ selection: RubySpanSelection, at point: CGPoint) -> Bool {
        // Spacing-pan hit-test: looser than inspection (allows ruby headroom / small outside margins).

        let range = displayRange(fromSourceRange: selection.highlightRange)
        guard range.location != NSNotFound, range.length > 0 else { return false }

        let baseHitInset: CGFloat = 12
        let rubyHitInset: CGFloat = 14

        // A) Base glyph hit-test (view coordinates), but with looser insets.
        if let uiRange = textRange(for: range) {
            let rects = selectionRects(for: uiRange)
                .map { $0.rect }
                .filter { $0.isNull == false && $0.isEmpty == false }
            if rects.contains(where: { $0.insetBy(dx: -baseHitInset, dy: -baseHitInset).contains(point) }) {
                return true
            }
        }

        // B) Ruby glyph hit-test (furigana overlay layers are content-space), also with looser insets.
        guard rubyAnnotationVisibility == .visible,
              let layers = rubyOverlayContainerLayer.sublayers,
              layers.isEmpty == false else {
            // If ruby is hidden, still allow spacing drags within the line band.
            return true
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
            if rInView.insetBy(dx: -rubyHitInset, dy: -rubyHitInset).contains(point) {
                return true
            }
        }

        // C) Fallback: within the line band we still allow spacing drags,
        // even if rects/layers are temporarily stale during layout settling.
        return true
    }

    /// Sets the active highlight range (DISPLAY coordinates).
    func applyInspectionHighlight(range: NSRange?) {
        selectionHighlightRange = range
    }

    /// Clears the highlight and emits nil selection.
    func clearInspectionHighlight() {
        applyInspectionHighlight(range: nil)
        notifySpanSelection(nil)
    }

    /// Emits the current span selection to the host.
    func notifySpanSelection(_ selection: RubySpanSelection?) {
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

    func makeContextMenu(for state: RubyContextMenuState, actionHandler: @escaping (RubyContextMenuAction) -> Void) -> UIMenu? {
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

    // MARK: - Tap -> index resolution

    /// Tap → UTF-16 index in the DISPLAY string (allows line-band + ruby headroom).
    func utf16IndexForTap(at point: CGPoint) -> Int? {
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
        guard let textRange = textRangeNearPoint(point),
              let closestPosition = textRange.start as UITextPosition? else { return nil }

        let offset = offset(from: beginningOfDocument, to: closestPosition)
        guard offset >= 0, offset < attributedLength else { return nil }

        return offset
    }

    /// Character-tap mode: only direct base glyph or ruby overlay hits (no whitespace snapping).
    func utf16IndexForCharacterTap(at point: CGPoint) -> Int? {
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

    /// Fallback: nearest `UITextRange` via UITextInput closest-position.
    func textRangeNearPoint(_ point: CGPoint) -> UITextRange? {
        guard let closestPosition = closestPosition(to: point) else { return nil }
        if let next = position(from: closestPosition, offset: 1) {
            return textRange(from: closestPosition, to: next)
        }
        if let previous = position(from: closestPosition, offset: -1) {
            return textRange(from: previous, to: closestPosition)
        }
        return nil
    }

    /// Snap a raw DISPLAY UTF-16 index to a nearby inspectable character (skips spaces/newlines/U+FFFC).
    func resolvedTextIndex(from candidate: Int) -> Int? {
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

    /// Find an inspectable character to the left on the same line.
    func inspectableIndex(before index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let character = text[cursor]
            if character.isNewline { break }
            if isInspectableCharacter(character) { return cursor }
        }
        return nil
    }

    /// Find an inspectable character to the right on the same line.
    func inspectableIndex(after index: String.Index, in text: String) -> String.Index? {
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

    /// UTF-16 code-unit offset for a `String.Index` (app uses UTF-16 `NSRange`).
    func utf16Offset(of index: String.Index, in text: String) -> Int? {
        guard let utf16Position = index.samePosition(in: text.utf16) else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Position)
    }

    /// Token-inspectable character (not whitespace/newline/U+FFFC spacer).
    func isInspectableCharacter(_ character: Character) -> Bool {
        if character.isNewline { return false }
        if character.isWhitespace { return false }
        if character == "\u{FFFC}" { return false }
        return true
    }

    /// SOURCE index → semantic span selection (highlightRange = span.range in SOURCE coords).
    func spanSelectionContext(forUTF16Index index: Int) -> RubySpanSelection? {
        guard let (tokenIndex, span) = semanticSpans.spanContext(containingUTF16Index: index) else { return nil }
        let spanRange = span.range
        guard spanRange.location != NSNotFound, spanRange.length > 0 else { return nil }
        return RubySpanSelection(tokenIndex: tokenIndex, semanticSpan: span, highlightRange: spanRange)
    }

    func inspectionDetails(forUTF16Index index: Int) -> (character: Character, utf16Range: NSRange, scalars: [String])? {
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

    func formattedCharacterDescription(_ character: Character) -> String {
        character.debugDescription
    }

    func logSpanResolution(for index: Int) {
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
