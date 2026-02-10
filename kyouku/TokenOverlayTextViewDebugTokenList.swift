import UIKit

extension TokenOverlayTextView {

    func emitDebugTokenListIfNeeded() {
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
}
