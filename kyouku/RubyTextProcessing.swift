import UIKit
import CoreText

enum RubyTextProcessing {
    private static let coreTextRubyAttribute = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
    static let headwordEnvelopePadAttribute = NSAttributedString.Key("HeadwordEnvelopePad")
    static let headwordEnvelopePadKernAttribute = NSAttributedString.Key("HeadwordEnvelopePadKern")
    static let interTokenSpacingKernAttribute = NSAttributedString.Key("InterTokenSpacingPadKern")

    private static func containsHanIdeograph(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs + extensions + compatibility ideographs.
            // Ranges chosen to cover modern Japanese kanji used in typical text.
            if (0x4E00...0x9FFF).contains(v) { return true } // Unified Ideographs
            if (0x3400...0x4DBF).contains(v) { return true } // Extension A
            if (0xF900...0xFAFF).contains(v) { return true } // Compatibility Ideographs
            if (0x2F800...0x2FA1F).contains(v) { return true } // Compatibility Supplement
            if (0x20000...0x2A6DF).contains(v) { return true } // Extension B
            if (0x2A700...0x2B73F).contains(v) { return true } // Extension C
            if (0x2B740...0x2B81F).contains(v) { return true } // Extension D
            if (0x2B820...0x2CEAF).contains(v) { return true } // Extension E
            if (0x2CEB0...0x2EBEF).contains(v) { return true } // Extension F
            if (0x30000...0x3134F).contains(v) { return true } // Extension G
        }
        return false
    }

    static func applyAnnotationVisibility(
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

    static func applyTokenColors(
        _ overlays: [RubyText.TokenOverlay],
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

    static func applyCustomizationHighlights(_ ranges: [NSRange], to attributedString: NSMutableAttributedString) {
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
        baseFont _: UIFont,
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
        // Heuristic: reserve meaningful horizontal slack so ruby never clips at line starts/ends,
        // especially when we center ruby over ink (excluding padding spacers).
        // Clamp so we don't over-inset on very large ruby sizes.
        return min(24, max(8, maxRubySize * 0.8))
    }

    private static func measureTypographicWidth(_ attributed: NSAttributedString) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func measureTypographicSize(_ attributed: NSAttributedString) -> CGSize {
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        // Use ascent+descent (typographic height). This matches how CoreText lays out glyphs
        // more closely than NSString.size(withAttributes:), and tends to agree better with
        // CATextLayer rendering.
        let height = max(0, ascent + descent)
        return CGSize(width: max(0, width), height: height)
    }

    static func headwordEnvelopePad(in attributed: NSAttributedString, displayRange: NSRange) -> CGFloat {
        guard displayRange.location != NSNotFound, displayRange.length > 0 else { return 0 }
        guard NSMaxRange(displayRange) <= attributed.length else { return 0 }
        let value = attributed.attribute(headwordEnvelopePadAttribute, at: displayRange.location, effectiveRange: nil)
        if let n = value as? NSNumber { return CGFloat(n.doubleValue) }
        if let cg = value as? CGFloat { return cg }
        if let dbl = value as? Double { return CGFloat(dbl) }
        return 0
    }

    static func applyHeadwordEnvelopePaddingWithoutSpacers(
        to attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat,
        enabled: Bool,
        interTokenSpacing: [Int: CGFloat] = [:]
    ) -> (NSAttributedString, TokenOverlayTextView.RubyIndexMap) {
        let hasInterTokenSpacing = interTokenSpacing.isEmpty == false
        guard (enabled || hasInterTokenSpacing), attributed.length > 0 else {
            return (attributed, .identity)
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(headwordEnvelopePadAttribute, range: full)
        mutable.removeAttribute(headwordEnvelopePadKernAttribute, range: full)
        mutable.removeAttribute(interTokenSpacingKernAttribute, range: full)

        let backing = mutable.string as NSString

        func readKern(at index: Int) -> CGFloat {
            guard index >= 0, index < mutable.length else { return 0 }
            let v = mutable.attribute(.kern, at: index, effectiveRange: nil)
            if let num = v as? NSNumber { return CGFloat(num.doubleValue) }
            if let cg = v as? CGFloat { return cg }
            if let dbl = v as? Double { return CGFloat(dbl) }
            return 0
        }

        if enabled {
            struct RubyRunInfo {
                let range: NSRange
                let reading: String
                let rubyFontSize: CGFloat
            }

            var rubyRuns: [RubyRunInfo] = []
            rubyRuns.reserveCapacity(64)

            attributed.enumerateAttribute(.rubyReadingText, in: full, options: []) { value, range, _ in
                guard let reading = value as? String, reading.isEmpty == false else { return }
                guard range.location != NSNotFound, range.length > 0 else { return }
                guard NSMaxRange(range) <= attributed.length else { return }

                let rubyFontSize: CGFloat = {
                    if let stored = attributed.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? Double {
                        return CGFloat(max(1.0, stored))
                    }
                    if let stored = attributed.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? CGFloat {
                        return max(1.0, stored)
                    }
                    if let stored = attributed.attribute(.rubyReadingFontSize, at: range.location, effectiveRange: nil) as? NSNumber {
                        return CGFloat(max(1.0, stored.doubleValue))
                    }
                    return max(1.0, defaultRubyFontSize)
                }()

                rubyRuns.append(.init(range: range, reading: reading, rubyFontSize: rubyFontSize))
            }

            for run in rubyRuns {
                guard let inkRange = TokenSpacingInvariantSource.trimmedInkRange(
                    in: run.range,
                    attributedLength: mutable.length,
                    backing: backing
                ) else { continue }

                let baseSub = mutable.attributedSubstring(from: inkRange)
                let baseForMeasurement = NSMutableAttributedString(attributedString: baseSub)
                if baseForMeasurement.length > 0,
                   baseForMeasurement.attribute(.font, at: 0, effectiveRange: nil) == nil {
                    baseForMeasurement.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: baseForMeasurement.length))
                }
                let baseWidth = measureTypographicWidth(baseForMeasurement)

                let rubyFont = baseFont.withSize(max(1.0, run.rubyFontSize))
                let rubyAttr = NSAttributedString(string: run.reading, attributes: [.font: rubyFont])
                let rubyWidth = measureTypographicWidth(rubyAttr)

                let delta = max(0, rubyWidth - baseWidth)
                guard delta > 0.01 else { continue }

                mutable.addAttribute(headwordEnvelopePadAttribute, value: delta, range: inkRange)

                var graphemeRanges: [NSRange] = []
                graphemeRanges.reserveCapacity(8)
                var idx = inkRange.location
                let upper = NSMaxRange(inkRange)
                while idx < upper {
                    let r = backing.rangeOfComposedCharacterSequence(at: idx)
                    guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= upper else { break }
                    graphemeRanges.append(r)
                    idx = NSMaxRange(r)
                }
                guard graphemeRanges.isEmpty == false else { continue }

                if graphemeRanges.count > 1 {
                    let perGap = delta / CGFloat(graphemeRanges.count - 1)
                    guard perGap > 0.01 else { continue }
                    for g in graphemeRanges.dropLast() {
                        let current = readKern(at: g.location)
                        let value = current + perGap
                        mutable.addAttribute(.kern, value: value, range: g)
                        mutable.addAttribute(headwordEnvelopePadKernAttribute, value: perGap, range: g)
                    }
                } else if let only = graphemeRanges.first {
                    let current = readKern(at: only.location)
                    let value = current + delta
                    mutable.addAttribute(.kern, value: value, range: only)
                    mutable.addAttribute(headwordEnvelopePadKernAttribute, value: delta, range: only)
                }
            }
        }

        if hasInterTokenSpacing {
            for (idx, width) in interTokenSpacing {
                guard idx > 0, idx <= mutable.length else { continue }
                let w = TokenSpacingInvariantSource.clampTokenSpacingWidth(width)
                guard abs(w) > TokenSpacingInvariantSource.tokenSpacingExistingWidthEpsilon else { continue }

                let prev = idx - 1
                guard prev >= 0, prev < backing.length else { continue }
                let composed = backing.rangeOfComposedCharacterSequence(at: prev)
                guard composed.location != NSNotFound, composed.length > 0 else { continue }

                let current = readKern(at: composed.location)
                mutable.addAttribute(.kern, value: current + w, range: composed)
                mutable.addAttribute(interTokenSpacingKernAttribute, value: w, range: composed)
            }
        }

        return (mutable, .identity)
    }

    static func applyRubyWidthPaddingAroundRunsIfNeeded(
        to attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat,
        enabled: Bool,
        headwordSpacingAmount: CGFloat = 1.0,
        interTokenSpacing: [Int: CGFloat] = [:]
    ) -> (NSAttributedString, TokenOverlayTextView.RubyIndexMap) {
        _ = headwordSpacingAmount
        return applyHeadwordEnvelopePaddingWithoutSpacers(
            to: attributed,
            baseFont: baseFont,
            defaultRubyFontSize: defaultRubyFontSize,
            enabled: enabled,
            interTokenSpacing: interTokenSpacing
        )
    }
}
