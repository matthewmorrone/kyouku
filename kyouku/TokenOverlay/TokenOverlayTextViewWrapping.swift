import UIKit
import CoreText

extension TokenOverlayTextView {

    func rebuildPreferredWrapBreakIndicesIfNeeded() {
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

    func shouldAllowWordBreakBeforeCharacter(at charIndex: Int) -> Bool {
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

    func isRubyWidthSpacer(atDisplayIndex displayIndex: Int) -> Bool {
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

    func nextNonSpacerDisplayIndex(startingAt displayIndex: Int) -> Int {
        guard let attributedText else { return displayIndex }
        var i = max(0, displayIndex)
        let upper = attributedText.length
        while i < upper, isRubyWidthSpacer(atDisplayIndex: i) {
            i += 1
        }
        return i
    }

    func hasRubyReadingAttribute(atDisplayIndex displayIndex: Int) -> Bool {
        guard let attributedText else { return false }
        let i = displayIndex
        guard i >= 0, i < attributedText.length else { return false }
        return attributedText.attribute(.furiganaReadingText, at: i, effectiveRange: nil) != nil
    }

    func isLeadingRubyWidthSpacerRun(startingAt spacerIndex: Int, nextNonSpacer: Int) -> Bool {
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
}
