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

    private var lastDebugTokenListSignature: Int? = nil
    private var debugTokenListDirty: Bool = false

    // SOURCE (unmodified) string corresponding to semantic span coordinates.
    // Display text (`attributedText`) may include ruby-width padding insertions.
    var debugSourceText: NSString? {
        didSet {
            debugTokenListDirty = true
            setNeedsLayout()
        }
    }

    private func emitDebugTokenListIfNeeded() {
        guard let handler = debugTokenListTextHandler else { return }
        guard let attributedText, attributedText.length > 0 else {
            handler("(No text)")
            return
        }
        guard semanticSpans.isEmpty == false else {
            handler("(No semantic spans)")
            return
        }

        // Signature so we don't recompute on every scroll tick.
        var hasher = Hasher()
        let sourceText = debugSourceText ?? (attributedText.string as NSString)
        hasher.combine(sourceText.length)
        hasher.combine(bounds.width.bitPattern)
        hasher.combine(bounds.height.bitPattern)
        hasher.combine(contentSize.width.bitPattern)
        hasher.combine(contentSize.height.bitPattern)
        hasher.combine(textContainerInset.top.bitPattern)
        hasher.combine(textContainerInset.left.bitPattern)
        hasher.combine(textContainerInset.right.bitPattern)
        hasher.combine(textContainerInset.bottom.bitPattern)
        hasher.combine(semanticSpans.count)
        for span in semanticSpans.prefix(256) {
            hasher.combine(span.range.location)
            hasher.combine(span.range.length)
        }

        // Include ruby overlay state so bisector coordinates update when overlay layout changes.
        hasher.combine(rubyAnnotationVisibility == .visible)
        if let rubyLayers = rubyOverlayContainerLayer.sublayers {
            hasher.combine(rubyLayers.count)
            for layer in rubyLayers.prefix(64) {
                guard let ruby = layer as? CATextLayer else { continue }
                if let loc = ruby.value(forKey: "rubyRangeLocation") as? Int,
                   let len = ruby.value(forKey: "rubyRangeLength") as? Int {
                    hasher.combine(loc)
                    hasher.combine(len)
                }
                hasher.combine(ruby.frame.midX.bitPattern)
            }
        }
        let signature = hasher.finalize()

        if debugTokenListDirty == false, let last = lastDebugTokenListSignature, last == signature {
            return
        }

        let lineRects = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: false)
        let doc = NSRange(location: 0, length: sourceText.length)
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
        let maxTokens = min(semanticSpans.count, 4096)
        var lines: [String] = []
        lines.reserveCapacity(min(128, maxTokens) * 3)

        func f1(_ v: CGFloat) -> String { String(format: "%.1f", v) }

        let showLineNumbers = rubyDebugShowLineNumbersEnabled
        lines.append("Semantic spans: \(semanticSpans.count) (showing first \(maxTokens))")
        lines.append(showLineNumbers ? "Format: L# S[idx] r=a-b «surface»" : "Format: S[idx] r=a-b «surface»")
        lines.append("")

        var lastLineDesc: String? = nil

        for idx in 0..<maxTokens {
            let span = semanticSpans[idx]
            let hasValidSourceRange = (span.range.location != NSNotFound && span.range.length > 0)
            let boundedBaseRange = hasValidSourceRange ? NSIntersectionRange(span.range, doc) : NSRange(location: NSNotFound, length: 0)

            // For readability/debugging: attach any immediate trailing punctuation (e.g. 、。!?…)
            // that sits between this token and the next token, so punctuation doesn't appear
            // “dropped” from the token list.
            let nextStart: Int = {
                let nextIndex = idx + 1
                guard nextIndex < maxTokens else { return sourceText.length }
                let next = semanticSpans[nextIndex].range
                guard next.location != NSNotFound else { return sourceText.length }
                return min(sourceText.length, next.location)
            }()

            let prevEnd: Int = {
                let prevIndex = idx - 1
                guard prevIndex >= 0 else { return 0 }
                let prev = semanticSpans[prevIndex].range
                guard prev.location != NSNotFound else { return 0 }
                return min(sourceText.length, NSMaxRange(prev))
            }()

            let effectiveSurfaceRange: NSRange = {
                guard boundedBaseRange.location != NSNotFound, boundedBaseRange.length > 0 else { return span.range }
                var start = boundedBaseRange.location
                var cursor = start

                // Attach any immediate leading punctuation/symbols (e.g. opening quotes/brackets)
                // that occur after a line break. We stop at whitespace/newlines.
                while cursor > prevEnd, cursor > 0 {
                    let r = sourceText.rangeOfComposedCharacterSequence(at: cursor - 1)
                    guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= sourceText.length else { break }
                    let s = sourceText.substring(with: r)
                    if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                    if isPunctuationOrSymbolOnly(s) == false { break }
                    start = r.location
                    cursor = start
                }

                var end = min(nextStart, NSMaxRange(boundedBaseRange))
                cursor = end
                while cursor < nextStart, cursor < sourceText.length {
                    let r = sourceText.rangeOfComposedCharacterSequence(at: cursor)
                    guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= sourceText.length else { break }
                    let s = sourceText.substring(with: r)
                    if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                    if isPunctuationOrSymbolOnly(s) == false { break }
                    end = NSMaxRange(r)
                    cursor = end
                }

                let len = max(0, end - start)
                guard len > 0 else { return boundedBaseRange }
                return NSRange(location: start, length: len)
            }()

            // Keep geometry stable: line/rect coordinates should reflect the base semantic span,
            // not the attached punctuation used for display.
            let displayRange = (boundedBaseRange.location != NSNotFound && boundedBaseRange.length > 0)
                ? displayRange(fromSourceRange: boundedBaseRange)
                : NSRange(location: NSNotFound, length: 0)

            let rects: [CGRect] = (displayRange.location != NSNotFound && displayRange.length > 0)
                ? unionRectsByLine(baseHighlightRectsInContentCoordinates(in: displayRange))
                : []
            let primary = rects.first
            let lineIndex = primary.flatMap { bestMatchingLineIndex(for: $0, candidates: lineRects) }

            let baseStart = hasValidSourceRange ? span.range.location : NSNotFound
            let baseEnd = hasValidSourceRange ? NSMaxRange(span.range) : NSNotFound
            let surface: String = {
                guard effectiveSurfaceRange.location != NSNotFound, effectiveSurfaceRange.length > 0 else { return "" }
                let bounded = NSIntersectionRange(effectiveSurfaceRange, doc)
                guard bounded.location != NSNotFound, bounded.length > 0 else { return "" }
                return sourceText.substring(with: bounded).replacingOccurrences(of: "\n", with: "\\n")
            }()

            let lineDesc = showLineNumbers ? (lineIndex.map { "L\($0)" } ?? "L?") : ""
            if showLineNumbers {
                if let last = lastLineDesc, last != lineDesc {
                    lines.append("")
                }
                lastLineDesc = lineDesc
            }

            let line = showLineNumbers
                ? "\(lineDesc) S[\(idx)] r=\(baseStart)-\(baseEnd) «\(surface)»"
                : "S[\(idx)] r=\(baseStart)-\(baseEnd) «\(surface)»"
            lines.append(line)
        }

        if semanticSpans.count > maxTokens {
            lines.append("… +\(semanticSpans.count - maxTokens) more")
        }

        // Bisector X coordinates (base + ruby + delta), per headword/furigana pair.
        // This uses the ruby overlay layers (already laid out) and their stored anchor metadata.
        func rubyString(from layer: CATextLayer) -> String {
            if let s = layer.string as? String { return s }
            if let a = layer.string as? NSAttributedString { return a.string }
            return ""
        }

        func computeBisectorLines() -> [String] {
            guard rubyAnnotationVisibility == .visible else { return [] }
            guard let rubyLayers = rubyOverlayContainerLayer.sublayers, rubyLayers.isEmpty == false else { return [] }

            struct BisectorKey: Hashable {
                // kind 0: semantic token index + ruby display range, kind 1: ruby display range
                let kind: UInt8
                let tokenIndex: Int
                let loc: Int
                let len: Int
            }
            var seen: Set<BisectorKey> = []
            seen.reserveCapacity(min(1024, rubyLayers.count))

            let maxPairs = min(rubyLayers.count, 1024)
            var out: [String] = []
            out.reserveCapacity(min(256, maxPairs) + 4)

            out.append("")
            out.append("Bisectors: (showing first \(maxPairs))")
            out.append("Format: L# B[idx] bx=.. rx=.. dx=.. r=a-b «base» 「ruby」")

            var emitted = 0

            for layer in rubyLayers.prefix(maxPairs) {
                guard let ruby = layer as? CATextLayer else { continue }
                let rubyRect = ruby.frame
                guard rubyRect.isNull == false, rubyRect.isEmpty == false else { continue }

                guard let loc = ruby.value(forKey: "rubyRangeLocation") as? Int,
                      let len = ruby.value(forKey: "rubyRangeLength") as? Int,
                      loc != NSNotFound,
                      len > 0 else {
                    continue
                }

                let key: BisectorKey = {
                    if let tokenIndex = ruby.value(forKey: "rubyTokenIndex") as? Int {
                        return BisectorKey(kind: 0, tokenIndex: tokenIndex, loc: loc, len: len)
                    }
                    return BisectorKey(kind: 1, tokenIndex: 0, loc: loc, len: len)
                }()
                if seen.contains(key) { continue }
                seen.insert(key)

                let displayRange = NSRange(location: loc, length: len)

                // Bisectors are only meaningful for headword glyphs. If the ruby layer's
                // tagged display range is punctuation-only (e.g. 、 。), skip it.
                if isPunctuationOrSymbolOnlyDisplayRange(displayRange) {
                    continue
                }

                let baseRects = textKit2AnchorRectsInContentCoordinates(for: displayRange, lineRectsInContent: lineRects)
                guard baseRects.isEmpty == false else { continue }
                let unions = unionRectsByLine(baseRects)
                guard unions.isEmpty == false else { continue }

                // Select the base union that this ruby layer was placed from.
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

                let baseCenterX = baseUnion.midX
                let rubyCenterX = rubyRect.midX
                let deltaX = rubyCenterX - baseCenterX

                let baseSourceRange = sourceRange(fromDisplayRange: displayRange)
                let baseSurface: String = {
                    guard baseSourceRange.location != NSNotFound, baseSourceRange.length > 0 else { return "" }
                    let bounded = NSIntersectionRange(baseSourceRange, doc)
                    guard bounded.location != NSNotFound, bounded.length > 0 else { return "" }
                    return sourceText.substring(with: bounded).replacingOccurrences(of: "\n", with: "\\n")
                }()

                let rubySurface = rubyString(from: ruby)
                let lineIndex = bestMatchingLineIndex(for: baseUnion, candidates: lineRects)
                let lineDesc = lineIndex.map { "L\($0)" } ?? "L?"

                out.append("\(lineDesc) B[\(emitted)] bx=\(f1(baseCenterX)) rx=\(f1(rubyCenterX)) dx=\(f1(deltaX)) r=\(loc)-\(loc+len) «\(baseSurface)» 「\(rubySurface)»")
                emitted += 1
            }

            return out
        }

        if rubyDebugBisectorsEnabled {
            lines.append(contentsOf: computeBisectorLines())
        }

        handler(lines.joined(separator: "\n"))
        lastDebugTokenListSignature = signature
        debugTokenListDirty = false
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

        func isPunctuationOrSymbolOnlySpanSurface(_ s: String) -> Bool {
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.isEmpty == false else { return false }
            let set = CharacterSet.punctuationCharacters.union(.symbols)
            for scalar in cleaned.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
                if set.contains(scalar) == false { return false }
            }
            return true
        }

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
            // Do not allow a preferred break at the start of a punctuation-only span (e.g. "、" "。" "!"),
            // otherwise punctuation tokens can become the first glyph on a wrapped line.
            if isPunctuationOrSymbolOnlySpanSurface(span.surface) {
                continue
            }
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

        func isDisplayWhitespace(_ u: unichar) -> Bool {
            switch u {
            case 0x0009, // \t
                 0x000A, // \n
                 0x000B,
                 0x000C,
                 0x000D, // \r
                 0x0020, // space
                 0x00A0, // no-break space
                 0x1680, // ogham space mark
                 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, // en/em/thin/hair spaces
                 0x200B, // zero width space
                 0x2028, // line separator
                 0x2029, // paragraph separator
                 0x202F, // narrow no-break space
                 0x205F, // medium mathematical space
                 0x3000: // ideographic space
                return true
            default:
                return false
            }
        }

        func nextNonWhitespaceOrSpacerUTF16(startingAt displayIndex: Int) -> unichar? {
            guard let attributedText else { return nil }
            let ns = attributedText.string as NSString
            guard ns.length > 0 else { return nil }
            var i = max(0, min(displayIndex, ns.length))

            func isHighSurrogate(_ u: unichar) -> Bool { (0xD800...0xDBFF).contains(u) }
            func isLowSurrogate(_ u: unichar) -> Bool { (0xDC00...0xDFFF).contains(u) }

            func isIgnorableFormatScalarBMP(_ u: unichar) -> Bool {
                switch u {
                case 0x00AD: return true // soft hyphen
                case 0x034F: return true // combining grapheme joiner
                case 0x061C: return true // arabic letter mark
                case 0x180E: return true // mongolian vowel separator (deprecated but seen)
                case 0x200C: return true // zero width non-joiner
                case 0x200D: return true // zero width joiner
                case 0x2060: return true // word joiner
                case 0xFEFF: return true // zero width no-break space / BOM
                default:
                    break
                }
                // Variation selectors (VS1..VS16)
                if (0xFE00...0xFE0F).contains(u) { return true }
                return false
            }

            func isIgnorableVariationSelectorSupplement(at index: Int) -> Bool {
                guard index + 1 < ns.length else { return false }
                let hi = ns.character(at: index)
                let lo = ns.character(at: index + 1)
                guard isHighSurrogate(hi), isLowSurrogate(lo) else { return false }
                let scalar = 0x10000 + ((Int(hi) - 0xD800) << 10) + (Int(lo) - 0xDC00)
                return (0xE0100...0xE01EF).contains(scalar)
            }

            while i < ns.length {
                if isRubyWidthSpacer(atDisplayIndex: i) {
                    i += 1
                    continue
                }

                if isIgnorableVariationSelectorSupplement(at: i) {
                    i += 2
                    continue
                }

                let u = ns.character(at: i)
                if isDisplayWhitespace(u) {
                    i += 1
                    continue
                }

                if isIgnorableFormatScalarBMP(u) {
                    i += 1
                    continue
                }
                return u
            }
            return nil
        }

        // Prevent common punctuation from becoming the first *visible* character on a wrapped line.
        // Note: breaks can happen before an inserted ruby-width spacer run (U+FFFC) and/or whitespace;
        // in that case we must peek past those to find the true leading glyph.
        if charIndex > 0, let u = nextNonWhitespaceOrSpacerUTF16(startingAt: charIndex) {
            switch u {
            // Commas
            case 0x002C, 0xFF0C, 0x3001, 0xFF64:
                return false

            // Periods
            case 0x002E, 0xFF0E, 0x3002, 0xFF61:
                return false

            // Exclamation / question
            case 0x0021, 0xFF01, 0x003F, 0xFF1F:
                return false

            // Colon / semicolon
            case 0x003A, 0xFF1A, 0x003B, 0xFF1B:
                return false

            // Ellipsis
            case 0x2026, 0x2025:
                return false

            // Japanese middle dot
            case 0x30FB:
                return false

            default:
                break
            }
        }

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
    private func scheduleLineStartBoundaryCorrectionIfNeeded() {
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
            if mutable.attribute(.rubyReadingText, at: index, effectiveRange: nil) != nil {
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
            let size = RubyText.measureTypographicSize(NSAttributedString(string: run.reading, attributes: attrs))
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { continue }

            let xUnclamped: CGFloat = {
                if let xr = caretXRangeInContentCoordinates(for: run.inkRange) {
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

    private func clampRubyXInContentCoordinates(_ x: CGFloat, width: CGFloat) -> CGFloat {
        guard x.isFinite, width.isFinite else { return x }

        // IMPORTANT:
        // Do NOT clamp ruby to the text container's left edge (inset/padding).
        // With headword padding OFF, ruby is allowed to overhang into the left margin.
        // With headword padding ON, width spacers should keep headword+ruby aligned.
        // The only clamping we do is to keep ruby from going fully off-screen.
        let left = contentOffset.x
        let right = contentOffset.x + bounds.width
        guard left.isFinite, right.isFinite else { return x }

        let minX = left
        let maxX = max(minX, right - width)
        return min(max(x, minX), maxX)
    }

    private func clampRubyXInViewCoordinates(_ x: CGFloat, width: CGFloat) -> CGFloat {
        guard x.isFinite, width.isFinite else { return x }

        // Mirror `clampRubyXInContentCoordinates` but in VIEW coordinates.
        // Keep ruby visible, but allow it to sit in the inset/margin area.
        let left: CGFloat = 0
        let right: CGFloat = bounds.width
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

    private lazy var tokenSpacingPanRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleTokenSpacingPan(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }()

    private var tokenSpacingActiveBoundaryUTF16: Int? = nil
    private var tokenSpacingStartValue: CGFloat = 0

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
    private let rubyHighlightLayer: CAShapeLayer = {
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
    private let rubyEnvelopeDebugRubyRectsLayer: CAShapeLayer = {
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
    private let rubyEnvelopeDebugBaseUnionLayer: CAShapeLayer = {
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
    private let rubyEnvelopeDebugRubyUnionLayer: CAShapeLayer = {
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
    private let rubyEnvelopeDebugFinalUnionLayer: CAShapeLayer = {
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

    private struct RubyRun {
        let range: NSRange
        let inkRange: NSRange
        let reading: String
        let fontSize: CGFloat
        let color: UIColor
    }

    private var cachedRubyRuns: [RubyRun] = []
    private var scrollRedrawScheduled: Bool = false
    private var hasDebugDictionaryCoverageAttributes: Bool = false
    private var isClampingHorizontalOffset: Bool = false
    private var softLineStartRubyPaddingFixScheduled: Bool = false
    private var lastSoftLineStartRubyPaddingFixSignature: Int = 0

    // Strategy 1: persistent overlay layers for ruby readings.
    // These layers are positioned during layout and then scroll automatically with the UITextView.
    private let rubyOverlayContainerLayer: CALayer = {
        let layer = CALayer()
        layer.masksToBounds = false
        return layer
    }()
    private var rubyOverlayDirty: Bool = true
    private var lastRubyOverlayLayoutSignature: Int = 0
    // The resolved ruby frames that were actually used to position CATextLayer(s)
    // during the most recent `layoutRubyOverlayIfNeeded()` pass.
    // Keyed by `RubyRun.inkRange.location`.
    private var rubyResolvedFramesByRunStart: [Int: CGRect] = [:]

    // Increments whenever we apply new attributed text; used so multi-pass corrections
    // can converge even when only attributes (e.g. `.kern`) change.
    private var attributedTextRevision: Int = 0
    private var suppressTextKit2LayoutCallbacks: Bool = false
    private var rubyOverlayRelayoutScheduled: Bool = false

    private func scheduleRubyOverlayRelayoutFromTextKit2() {
        guard rubyAnnotationVisibility == .visible else { return }
        guard cachedRubyRuns.isEmpty == false else { return }
        guard rubyOverlayRelayoutScheduled == false else { return }
        rubyOverlayRelayoutScheduled = true

        // TextKit 2 is often viewport-lazy. When new fragments are laid out (e.g. after scrolling
        // or after a settings-driven geometry nudge), our prior ruby overlay frames can be stale.
        // Coalesce to next runloop to avoid thrashing during incremental layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rubyOverlayRelayoutScheduled = false
            guard self.rubyAnnotationVisibility == .visible else { return }
            guard self.cachedRubyRuns.isEmpty == false else { return }
            self.rubyOverlayDirty = true
            self.needsHighlightUpdate = true
            self.setNeedsLayout()
        }
    }

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
    private static let rubyDebugBisectorsDefaultsKey = "rubyDebugBisectors"
    private static let rubyDebugShowHeadwordBisectorsDefaultsKey = "RubyDebug.showHeadwordBisectors"
    private static let rubyDebugShowRubyBisectorsDefaultsKey = "RubyDebug.showRubyBisectors"
    private static let headwordDebugRectsDefaultsKey = "rubyHeadwordDebugRects"
    private static let rubyDebugLineBandsDefaultsKey = "rubyDebugLineBands"
    private static let headwordLineBandsDefaultsKey = "rubyHeadwordLineBands"
    private static let rubyLineBandsDefaultsKey = "rubyFuriganaLineBands"
    private static let rubyDebugShowLineNumbersDefaultsKey = "RubyDebug.showLineBandLabels"

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

    private var rubyDebugBisectorsEnabled: Bool {
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

    private var rubyDebugShowLineNumbersEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.rubyDebugShowLineNumbersDefaultsKey) != nil {
            return defaults.bool(forKey: Self.rubyDebugShowLineNumbersDefaultsKey)
        }
        return true
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
            if self.rubyDebugRectsEnabled {
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

        if headwordDebugRectsEnabled {
            updateHeadwordDebugRects()
        }
        if rubyDebugRectsEnabled {
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

        // Put dictionary outlines below selection highlights.
        highlightOverlayContainerLayer.addSublayer(debugDictionaryOutlineLevel1Layer)
        highlightOverlayContainerLayer.addSublayer(debugDictionaryOutlineLevel2Layer)
        highlightOverlayContainerLayer.addSublayer(debugDictionaryOutlineLevel3PlusLayer)
        highlightOverlayContainerLayer.addSublayer(rubyHighlightLayer)
        highlightOverlayContainerLayer.addSublayer(baseHighlightLayer)

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

        // NOTE: Previously we ran a soft-wrap mitigation that shifted line-start headword-padding
        // spacers to the trailing side to avoid “ruby jutting left”. Now that ruby anchoring uses
        // `RubyRun.inkRange` (visible glyph bounds), that mitigation can remove the intended left
        // padding. Keep it available for future diagnostics, but do not run it by default.

        // Ruby highlight geometry is derived from the ruby overlay layers.
        // Ensure overlays are laid out first so highlight rects can match actual ruby bounds.
        layoutRubyOverlayIfNeeded()

        // Token widths are expanded pre-layout (see `RubyTextProcessing.applyRubyWidthPaddingAroundRunsIfNeeded`).
        // Do not apply any post-layout, line-level padding/correction here.

        // Update debug token listing (used by PasteView's popover) after layout/ruby overlays.
        emitDebugTokenListIfNeeded()

        // Highlights are content-space overlays; keep their container sized to content.
        // This avoids stale frames when contentSize changes but selection does not.
        highlightOverlayContainerLayer.frame = CGRect(origin: .zero, size: contentSize)

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

        if rubyDebugBisectorsEnabled {
            installRubyBisectorDebugContainerIfNeeded()
            updateRubyHeadwordBisectors()
        } else {
            resetRubyBisectorDebugLayers()
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

    @available(iOS 15.0, *)
    private func scheduleSoftLineStartRubyPaddingFixIfNeeded() {
        // Headword-padding inserts symmetric leading/trailing width spacers to give centered
        // ruby enough slack. When a line *soft wraps*, the new visual line can begin with a
        // leading spacer run, which makes the ruby appear to jut into the left margin.
        // Detect those line starts and shift the leading spacer width to the trailing side.

        guard padHeadwordSpacing else { return }
        guard wrapLines else { return }
        guard softLineStartRubyPaddingFixScheduled == false else { return }
        guard let attributedText, attributedText.length > 0 else { return }
        guard cachedRubyRuns.isEmpty == false else { return }
        guard let tlm = textLayoutManager else { return }

        // Re-run when the wrapping width changes, or when the attributed text changes.
        // (Soft line starts are width-dependent.)
        var hasher = Hasher()
        hasher.combine(attributedText.length)
        hasher.combine(cachedRubyRuns.count)
        hasher.combine(Int((textContainerInset.left * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainerInset.right * 10).rounded(.toNearestOrEven)))
        hasher.combine(Int((textContainer.size.width * 10).rounded(.toNearestOrEven)))
        let signature = hasher.finalize()
        guard signature != lastSoftLineStartRubyPaddingFixSignature else { return }

        // Ensure layout so line fragments exist for the current viewport.
        tlm.ensureLayout(for: tlm.documentRange)

        guard let adjusted = softLineStartRubyPaddingAdjustedTextIfNeeded(from: attributedText) else {
            // No changes needed; remember this configuration so we don't rescan every pass.
            lastSoftLineStartRubyPaddingFixSignature = signature
            return
        }

        softLineStartRubyPaddingFixScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.softLineStartRubyPaddingFixScheduled = false
            self.lastSoftLineStartRubyPaddingFixSignature = signature
            self.applyAttributedText(adjusted)
        }
    }

    @available(iOS 15.0, *)
    private func softLineStartRubyPaddingAdjustedTextIfNeeded(from text: NSAttributedString) -> NSAttributedString? {
        guard textLayoutManager != nil else { return nil }
        guard text.length > 0 else { return nil }

        let visibleLineStartIndices = textKit2VisibleLineStartCharacterIndices()
        guard visibleLineStartIndices.isEmpty == false else { return nil }

        let backing = text.string as NSString
        let mutable = NSMutableAttributedString(attributedString: text)

        func isSpacer(_ index: Int) -> Bool {
            guard index >= 0, index < mutable.length else { return false }
            if mutable.attribute(kCTRunDelegateAttributeName as NSAttributedString.Key, at: index, effectiveRange: nil) != nil {
                return true
            }
            if backing.length > 0, index < backing.length {
                return backing.character(at: index) == 0xFFFC
            }
            return false
        }

        func hasRuby(_ index: Int) -> Bool {
            guard index >= 0, index < mutable.length else { return false }
            return mutable.attribute(.rubyReadingText, at: index, effectiveRange: nil) != nil
        }

        func nextNonSpacer(from start: Int) -> Int {
            var i = max(0, start)
            while i < mutable.length, isSpacer(i) {
                i += 1
            }
            return i
        }

        func isLeadingSpacerRun(startingAt spacerIndex: Int, nextNonSpacer: Int) -> Bool {
            // Leading spacer(s): immediately followed by a ruby-bearing headword character.
            // Trailing spacer(s): immediately preceded by a ruby-bearing headword character.
            guard hasRuby(nextNonSpacer) else { return false }

            var prev = spacerIndex - 1
            while prev >= 0, isSpacer(prev) {
                prev -= 1
            }
            if prev >= 0, hasRuby(prev) {
                return false
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

        var didChange = false

        for start in visibleLineStartIndices {
            guard start >= 0, start < mutable.length else { continue }

            // Ignore true paragraph/newline starts; those are handled during preprocessing.
            if start > 0 {
                let prev = backing.character(at: start - 1)
                if let scalar = UnicodeScalar(prev), CharacterSet.newlines.contains(scalar) {
                    continue
                }
            }

            guard isSpacer(start) else { continue }
            let next = nextNonSpacer(from: start)
            guard next > start, next < mutable.length else { continue }
            guard isLeadingSpacerRun(startingAt: start, nextNonSpacer: next) else { continue }

            // Find the ruby run this line-start belongs to.
            guard let run = cachedRubyRuns.first(where: { NSLocationInRange(next, $0.range) }) else { continue }

            // Sum and zero out all leading spacer widths at this visual line start.
            var leadingWidth: CGFloat = 0
            var i = start
            while i < next {
                guard isSpacer(i) else { break }
                guard hasRuby(i) else { break }
                let w = spacerWidth(at: i)
                if w > 0.0001 {
                    leadingWidth += w
                    setSpacerWidth(0, at: i)
                    didChange = true
                }
                i += 1
            }
            guard leadingWidth > 0.0001 else { continue }

            // Add that width onto the trailing spacer of the same ruby run.
            let runEndExclusive = min(mutable.length, NSMaxRange(run.range))
            var tail = runEndExclusive - 1
            var trailingSpacerIndex: Int? = nil
            while tail >= run.range.location {
                if isSpacer(tail) == false { break }
                if hasRuby(tail) == false { break }
                trailingSpacerIndex = tail
                tail -= 1
            }
            if let trailingSpacerIndex {
                let existing = spacerWidth(at: trailingSpacerIndex)
                setSpacerWidth(existing + leadingWidth, at: trailingSpacerIndex)
                didChange = true
            }
        }

        return didChange ? mutable : nil
    }

    @available(iOS 15.0, *)
    private func textKit2VisibleLineStartCharacterIndices() -> [Int] {
        guard let tlm = textLayoutManager else { return [] }

        let inset = textContainerInset
        let offset = contentOffset

        // Mirror the visible rect logic used by `textKit2LineTypographicRectsInViewCoordinates`.
        let extraY = max(16, rubyHighlightHeadroom + 12)
        let viewBounds = CGRect(origin: .zero, size: bounds.size)
        let visibleRectInView = viewBounds.insetBy(dx: -4, dy: -extraY)

        var starts: [Int] = []
        starts.reserveCapacity(64)

        tlm.ensureLayout(for: tlm.documentRange)
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            let origin = fragment.layoutFragmentFrame.origin
            for line in fragment.textLineFragments {
                // Filter to visible line fragments to keep this cheap on long documents.
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
                let start = cr.location
                if start != NSNotFound {
                    starts.append(start)
                }
            }
            return true
        }

        // Unique + stable ordering.
        return Array(Set(starts)).sorted()
    }

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

        if showTokenPositions, semanticSpans.isEmpty == false {
            let visible = visibleUTF16Range()
            let expandedVisible = visible.map { expandRange($0, by: 128) }
            let lineRects = textKit2LineTypographicRectsInContentCoordinates(visibleOnly: false)

            func f1(_ v: CGFloat) -> String { String(format: "%.1f", v) }
            func formatRect(_ r: CGRect) -> String {
                "x=\(f1(r.minX)) y=\(f1(r.minY)) w=\(f1(r.width)) h=\(f1(r.height))"
            }

            var printed = 0
            let maxPrinted = 24

            for (idx, span) in semanticSpans.enumerated() {
                if let expandedVisible {
                    if NSIntersectionRange(span.range, expandedVisible).length <= 0 {
                        continue
                    }
                }

                let displaySpanRange = displayRange(fromSourceRange: span.range)
                guard displaySpanRange.location != NSNotFound, displaySpanRange.length > 0 else { continue }
                guard isHardBoundaryOnly(range: displaySpanRange) == false else { continue }

                let rects = unionRectsByLine(baseHighlightRectsInContentCoordinates(in: displaySpanRange))
                guard rects.isEmpty == false else { continue }

                let lineIndices: [Int] = rects.compactMap { bestMatchingLineIndex(for: $0, candidates: lineRects) }
                let lineDesc: String = {
                    let unique = Array(Set(lineIndices)).sorted()
                    if unique.isEmpty { return "L?" }
                    if unique.count == 1 { return "L\(unique[0])" }
                    let joined = unique.prefix(4).map(String.init).joined(separator: ",")
                    return unique.count > 4 ? "L\(joined),…" : "L\(joined)"
                }()

                let primary = rects[0]
                let surface = span.surface.replacingOccurrences(of: "\n", with: "\\n")
                let start = span.range.location
                let end = NSMaxRange(span.range)
                lines.append(
                    "T[\(idx)] r=\(start)-\(end) \(lineDesc) mid=\(f1(primary.midX)),\(f1(primary.midY)) \(formatRect(primary)) «\(surface)»"
                )

                printed += 1
                if printed >= maxPrinted {
                    let remaining = max(0, semanticSpans.count - (idx + 1))
                    if remaining > 0 {
                        lines.append("… +\(remaining) more")
                    }
                    break
                }
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
        let showLineBandLabels: Bool = (headwordLineBandsEnabled || rubyLineBandsEnabled) && rubyDebugShowLineNumbersEnabled
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

        // A simple left-edge guide so alignment at the start of lines is easy to inspect.
        let leftGuidePath = CGMutablePath()
        let leftGuideX: CGFloat = {
            if let minX = lineRectsInContent.map({ $0.minX }).min(), minX.isFinite {
                return minX
            }
            return max(0, textContainerInset.left)
        }()
        if contentSize.height.isFinite, contentSize.height > 0 {
            leftGuidePath.move(to: CGPoint(x: leftGuideX, y: 0))
            leftGuidePath.addLine(to: CGPoint(x: leftGuideX, y: contentSize.height))
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

        rubyBisectorDebugContainerLayer.isHidden =
            alignedHeadwordPath.isEmpty &&
            misalignedHeadwordPath.isEmpty &&
            alignedRubyPath.isEmpty &&
            misalignedRubyPath.isEmpty &&
            leftGuidePath.isEmpty
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

                let size = RubyText.measureTypographicSize(NSAttributedString(string: run.reading, attributes: attrs))
                let xUnclamped: CGFloat = {
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
                let x: CGFloat = clampRubyXInViewCoordinates(xUnclamped, width: size.width)

                // Bottom-anchor ruby near the headword: keep a small consistent gap and let
                // the top edge move when ruby size changes.
                let gap = max(0, rubyBaselineGap)
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

            func isHardBoundaryGlyph(_ s: String) -> Bool {
                if s == "\u{FFFC}" { return true }
                if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
                let set = CharacterSet.punctuationCharacters.union(.symbols)
                for scalar in s.unicodeScalars {
                    if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
                    if set.contains(scalar) == false { return false }
                }
                return true
            }

            // Derive an "ink" range for geometry/bisectors by trimming invisible ruby-width
            // spacers (U+FFFC) and pure whitespace at the start/end of the attributed run.
            // This keeps alignment debugging tied to the visible glyphs, even when we pad
            // headword spacing for wide ruby.
            let backing = text.string as NSString
            let upperBound = min(text.length, NSMaxRange(range))
            var inkStart = range.location
            var inkEndExclusive = upperBound
            var foundInkGlyph: Bool = false

            if range.location < upperBound {
                // Trim leading.
                var idx = range.location
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

                if foundInkGlyph == false {
                    // This ruby attribute range contains only hard-boundary glyphs (e.g. U+FFFC
                    // padding spacers / whitespace / punctuation). These can be introduced by
                    // headword padding logic and should not generate ruby overlays/bisectors.
                    return
                }

                // Trim trailing.
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

            let inkRange: NSRange = {
                let len = max(0, inkEndExclusive - inkStart)
                guard inkStart != NSNotFound, len > 0 else { return range }
                return NSRange(location: inkStart, length: len)
            }()

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

    private func updateSelectionHighlightPath() {
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
                let rects = baseHighlightRectsInContentCoordinates(in: range)
                if rects.isEmpty == false { return rects }
            }

            // Fallback: selection rects are view-coordinate; convert to content-coordinate.
            let rectsInView = baseHighlightRects(in: range)
            guard rectsInView.isEmpty == false else { return [] }
            let offset = contentOffset
            return rectsInView.map { $0.offsetBy(dx: offset.x, dy: offset.y) }
        }()

        var highlightRectsInContent = unionRectsByLine(baseRectsInContent)
        let baseRectUnionInContent: CGRect = {
            var u = CGRect.null
            for r in highlightRectsInContent {
                u = u.isNull ? r : u.union(r)
            }
            return u
        }()

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

        let highlightPath = CGMutablePath()
        let highlightOutset: CGFloat = 5
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

    private func updateTokenSpacingGestureState() {
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

        // Drag-selection and spacing-drag are mutually exclusive.
        updateTokenSpacingGestureState()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === tokenSpacingPanRecognizer {
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
            guard let boundary = resolveTokenSpacingBoundary(selection: selection, tapPoint: point, length: length, backing: backing) else {
                return false
            }
            // Ensure the boundary is valid for persistence.
            guard boundary > 0, boundary < length else { return false }
            return true
        }
        return true
    }

    private func resolveTokenSpacingBoundary(
        selection: RubySpanSelection,
        tapPoint: CGPoint,
        length: Int,
        backing: NSString
    ) -> Int? {
        let start = selection.highlightRange.location
        let end = NSMaxRange(selection.highlightRange)

        // Candidate boundaries around this token.
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

        // If either side already has spacing, stick to it so dragging left can decrease.
        if let provider = tokenSpacingValueProvider {
            let leadingValue = (leadingOK && leading != nil) ? provider(leading!) : 0
            let trailingValue = (trailingOK && trailing != nil) ? provider(trailing!) : 0
            let hasLeading = abs(leadingValue) > 0.25
            let hasTrailing = abs(trailingValue) > 0.25

            if hasLeading && !hasTrailing { return leading }
            if hasTrailing && !hasLeading { return trailing }
        }

        // Default: leading boundary (moves the touched token). If unavailable, use trailing.
        if leadingOK, let leading { return leading }
        if trailingOK, let trailing { return trailing }
        return nil
    }

    @objc
    private func handleTokenSpacingPan(_ recognizer: UIPanGestureRecognizer) {
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
            return resolveTokenSpacingBoundary(selection: selection, tapPoint: point, length: length, backing: backing)
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

        case .changed:
            guard let boundary = tokenSpacingActiveBoundaryUTF16 else { return }
            let delta = recognizer.translation(in: self).x
            let proposed = tokenSpacingStartValue + delta
            let clamped = max(-60, min(proposed, 120))
            tokenSpacingChangedHandler(boundary, clamped, false)

        case .ended:
            guard let boundary = tokenSpacingActiveBoundaryUTF16 else { return }
            let delta = recognizer.translation(in: self).x
            let proposed = tokenSpacingStartValue + delta
            let clamped = max(-60, min(proposed, 120))
            tokenSpacingChangedHandler(boundary, clamped, true)
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

    private func pointHitsSemanticSpanForSpacing(_ selection: RubySpanSelection, at point: CGPoint) -> Bool {
        // Spacing drag should feel easier to initiate than token inspection:
        // - allow taps in the ruby headroom above the base glyphs
        // - allow taps slightly outside tight selection rects (between tokens)
        // We still require the point to be inside the visible line band so empty gutter drags don't trigger.
        guard pointHitsVisibleLineBand(point) else { return false }

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

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, didCompleteLayoutFor textRange: NSTextRange) {
        // TextKit 2 can lay out fragments lazily; if we render ruby overlays before a fragment's
        // final coordinates are known, a subset of lines can appear mis-positioned until a later
        // navigation/geometry event forces relayout. Coalesce an overlay refresh after layout.
        guard suppressTextKit2LayoutCallbacks == false else { return }
        scheduleRubyOverlayRelayoutFromTextKit2()
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

