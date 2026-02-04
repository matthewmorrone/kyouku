import UIKit
import CoreText

enum RubyTextProcessing {
    private static let coreTextRubyAttribute = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

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
        baseFont: UIFont,
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

    private static func makeWidthAttachmentAttributes(width: CGFloat) -> [NSAttributedString.Key: Any] {
        guard width.isFinite else {
            return [
                .foregroundColor: UIColor.clear,
                kCTForegroundColorAttributeName as NSAttributedString.Key: UIColor.clear.cgColor
            ]
        }
        let w = width

        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { ref in
                Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).release()
            },
            getAscent: { ref in
                let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                _ = data
                return 0
            },
            getDescent: { _ in 0 },
            getWidth: { ref in
                let data = Unmanaged<NSNumber>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue()
                return CGFloat(data.doubleValue)
            }
        )

        let boxed = NSNumber(value: Double(w))
        let ref = Unmanaged.passRetained(boxed).toOpaque()
        let delegate = CTRunDelegateCreate(&callbacks, ref)

        return [
            kCTRunDelegateAttributeName as NSAttributedString.Key: delegate as Any,
            .foregroundColor: UIColor.clear,
            // CoreText draws the replacement glyph; make it truly invisible.
            kCTForegroundColorAttributeName as NSAttributedString.Key: UIColor.clear.cgColor
        ]
    }

    static func applyRubyWidthPaddingAroundRunsIfNeeded(
        to attributed: NSAttributedString,
        baseFont: UIFont,
        defaultRubyFontSize: CGFloat,
        enabled: Bool,
        interTokenSpacing: [Int: CGFloat] = [:]
    ) -> (NSAttributedString, TokenOverlayTextView.RubyIndexMap) {
        let canPadRuby = enabled
        let hasInterTokenSpacing = interTokenSpacing.isEmpty == false
        guard (canPadRuby || hasInterTokenSpacing), attributed.length > 0 else {
            return (attributed, .identity)
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: mutable.length)

        // Insert display-only spacers (U+FFFC + CTRunDelegate width).
        // These are display-only and tracked via RubyIndexMap so selection/semantic ranges stay in SOURCE coordinates.
        enum SpacerKind {
            case rubyPadding(reading: String, rubyFontSize: CGFloat)
            case interToken
        }

        struct SpacerInsertion {
            let insertAtSourceIndex: Int
            let width: CGFloat
            let kind: SpacerKind
        }
        var insertions: [SpacerInsertion] = []
        insertions.reserveCapacity(64)

        struct RubyRunInfo {
            let range: NSRange
            let reading: String
            let rubyFontSize: CGFloat
        }
        var rubyRuns: [RubyRunInfo] = []
        rubyRuns.reserveCapacity(64)

        if canPadRuby {
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
        }

        func isPunctuationOrSymbolOnly(_ surface: String) -> Bool {
            if surface.isEmpty { return false }
            let set = CharacterSet.punctuationCharacters.union(.symbols)
            for scalar in surface.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { return false }
                if set.contains(scalar) == false { return false }
            }
            return true
        }

        let backing = mutable.string as NSString
        let length = mutable.length

        // Expand ruby-bearing runs forward over immediate trailing punctuation.
        // (We intentionally do NOT include whitespace/newlines.)
        if canPadRuby {
            for run in rubyRuns {
                let start = run.range.location
                let originalEnd = NSMaxRange(run.range)
                guard start != NSNotFound, originalEnd <= length else { continue }

                var end = originalEnd
                var cursor = end
                while cursor < length {
                    let r = backing.rangeOfComposedCharacterSequence(at: cursor)
                    guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= length else { break }
                    let s = backing.substring(with: r)
                    if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        break
                    }
                    if isPunctuationOrSymbolOnly(s) == false {
                        break
                    }
                    // Do not steal punctuation already claimed by another ruby run.
                    if mutable.attribute(.rubyReadingText, at: r.location, effectiveRange: nil) != nil {
                        break
                    }
                    mutable.addAttribute(.rubyReadingText, value: run.reading, range: r)
                    mutable.addAttribute(.rubyReadingFontSize, value: run.rubyFontSize, range: r)
                    end = NSMaxRange(r)
                    cursor = end
                }
                _ = end
            }
        }

        if canPadRuby {
            for run in rubyRuns {
                let range = run.range
                let reading = run.reading
                let rubyFontSize = run.rubyFontSize

                guard range.location != NSNotFound, range.length > 0 else { continue }
                guard NSMaxRange(range) <= mutable.length else { continue }

                // Determine the visible "ink" range (exclude padding spacers, whitespace, and punctuation/symbols).
                // Padding is applied symmetrically around this ink range so the token's effective layout width
                // matches the ruby width without shifting ruby relative to its base glyphs.
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

                let upperBound = min(mutable.length, NSMaxRange(range))
                var inkStart = range.location
                var inkEndExclusive = upperBound
                var foundInkGlyph = false

                if range.location < upperBound {
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

                    if foundInkGlyph {
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
                }

                guard foundInkGlyph else { continue }
                let inkLength = max(0, inkEndExclusive - inkStart)
                guard inkLength > 0 else { continue }

                // Measure base width for the visible glyphs only.
                let inkRange = NSRange(location: inkStart, length: inkLength)
                let baseSub = mutable.attributedSubstring(from: inkRange)
                let baseForMeasurement = NSMutableAttributedString(attributedString: baseSub)
                if baseForMeasurement.length > 0,
                   baseForMeasurement.attribute(.font, at: 0, effectiveRange: nil) == nil {
                    baseForMeasurement.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: baseForMeasurement.length))
                }
                let baseWidth = measureTypographicWidth(baseForMeasurement)

                let rubyFont = baseFont.withSize(max(1.0, rubyFontSize))
                let rubyAttr = NSAttributedString(string: reading, attributes: [.font: rubyFont])
                let rubyWidth = measureTypographicWidth(rubyAttr)

                // Symmetric token expansion: effective layout width becomes rubyWidth.
                let extra = max(0, rubyWidth) - baseWidth
                guard extra > 0.01 else { continue }

                let half = extra * 0.5
                if half > 0.01 {
                    insertions.append(
                        .init(
                            insertAtSourceIndex: inkStart,
                            width: half,
                            kind: .rubyPadding(reading: reading, rubyFontSize: rubyFontSize)
                        )
                    )
                    insertions.append(
                        .init(
                            insertAtSourceIndex: inkEndExclusive,
                            width: half,
                            kind: .rubyPadding(reading: reading, rubyFontSize: rubyFontSize)
                        )
                    )
                }
            }
        }

        if hasInterTokenSpacing {
            for (idx, width) in interTokenSpacing {
                guard idx > 0, idx < length else { continue }
                guard width.isFinite else { continue }
                let w = width
                guard abs(w) > 0.25 else { continue }
                insertions.append(.init(insertAtSourceIndex: idx, width: w, kind: .interToken))
            }
        }

        guard insertions.isEmpty == false else {
            return (mutable, .identity)
        }

        // Apply insertions from end to start so indices remain stable.
        let sorted = insertions.sorted {
            if $0.insertAtSourceIndex != $1.insertAtSourceIndex {
                return $0.insertAtSourceIndex > $1.insertAtSourceIndex
            }
            return $0.width > $1.width
        }

        for item in sorted {
            let attachmentChar = "\u{FFFC}" // object replacement character
            let attrs = makeWidthAttachmentAttributes(width: item.width)
            let insert = NSMutableAttributedString(string: attachmentChar, attributes: attrs)
            insert.addAttribute(.font, value: baseFont, range: NSRange(location: 0, length: insert.length))

            switch item.kind {
            case .rubyPadding(let reading, let rubyFontSize):
                // Extend ruby attributes across the spacers so the ruby run's measured base width includes padding.
                insert.addAttribute(.rubyReadingText, value: reading, range: NSRange(location: 0, length: insert.length))
                insert.addAttribute(.rubyReadingFontSize, value: rubyFontSize, range: NSRange(location: 0, length: insert.length))
            case .interToken:
                break
            }

            let safeIndex = max(0, min(mutable.length, item.insertAtSourceIndex))

            // CRITICAL: preserve paragraph metrics on inserted spacers.
            // TextKit can resolve paragraph style per-run; if a visual line begins with a
            // spacer that lacks `.paragraphStyle`, line spacing/headroom may collapse and
            // ruby can overlap adjacent lines.
            if mutable.length > 0 {
                let sampleIndex: Int = {
                    if safeIndex < mutable.length { return safeIndex }
                    return max(0, mutable.length - 1)
                }()
                if let paragraph = mutable.attribute(.paragraphStyle, at: sampleIndex, effectiveRange: nil) {
                    insert.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: insert.length))
                }
            }

            mutable.insert(insert, at: safeIndex)
        }

        let insertionPositions = insertions.map { $0.insertAtSourceIndex }.sorted()
        return (mutable, TokenOverlayTextView.RubyIndexMap(insertionPositions: insertionPositions))
    }
}
