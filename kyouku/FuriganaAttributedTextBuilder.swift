import Foundation
import UIKit
import CoreText
import OSLog

enum FuriganaAttributedTextBuilder {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "FuriganaBuilder")
    private static func log(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.info("[\(file):\(line)] \(function): \(message)")
    }

    static func build(
        text: String,
        textSize: Double,
        furiganaSize: Double,
        context: String = "general",
        overrides: [ReadingOverride] = []
    ) async throws -> NSAttributedString {
        guard text.isEmpty == false else {
            log("[\(context)] Skipping build because the input text is empty.")
            return NSAttributedString(string: text)
        }

        let buildStart = CFAbsoluteTimeGetCurrent()
        let annotated = try await computeAnnotatedSpans(text: text, context: context, overrides: overrides)
        let attributed = project(
            text: text,
            annotatedSpans: annotated,
            textSize: textSize,
            furiganaSize: furiganaSize,
            context: context
        )
        let totalDuration = elapsedMilliseconds(since: buildStart)
        log("[\(context)] Finished furigana build in \(totalDuration) ms.")
        return attributed
    }

    static func computeAnnotatedSpans(
        text: String,
        context: String = "general",
        overrides: [ReadingOverride] = []
    ) async throws -> [AnnotatedSpan] {
        guard text.isEmpty == false else {
            log("[\(context)] Skipping span computation because the input text is empty.")
            return []
        }

        log("[\(context)] Starting furigana span computation for \(text.count) characters.")
        let start = CFAbsoluteTimeGetCurrent()

        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let segmented = try await SegmentationService.shared.segment(text: text)
        let adjustedSpans = applySpanOverrides(
            spans: segmented,
            overrides: overrides,
            text: text
        )

        let removedSpans = segmented.filter { original in adjustedSpans.contains(original) == false }
        let addedSpans = adjustedSpans.filter { candidate in segmented.contains(candidate) == false }
        if removedSpans.isEmpty == false || addedSpans.isEmpty == false {
            let removedDescription = removedSpans.isEmpty ? "none" : describe(spans: removedSpans)
            let addedDescription = addedSpans.isEmpty ? "none" : describe(spans: addedSpans)
            log("[\(context)] override diff removed=[\(removedDescription)] added=[\(addedDescription)]")
        }

        let segmentationDuration = elapsedMilliseconds(since: segmentationStart)
        log("[\(context)] Segmentation spans found: \(adjustedSpans.count) in \(segmentationDuration) ms.")

        let attachmentStart = CFAbsoluteTimeGetCurrent()
        let annotated = await SpanReadingAttacher().attachReadings(text: text, spans: adjustedSpans)
        let resolvedAnnotated = applyReadingOverrides(
            annotated,
            overrides: overrides
        )
        let attachmentDuration = elapsedMilliseconds(since: attachmentStart)
        log("[\(context)] Annotated spans ready for projection: \(resolvedAnnotated.count) in \(attachmentDuration) ms.")

        let totalDuration = elapsedMilliseconds(since: start)
        log("[\(context)] Completed span computation in \(totalDuration) ms.")
        return resolvedAnnotated
    }

    static func project(
        text: String,
        annotatedSpans: [AnnotatedSpan],
        textSize: Double,
        furiganaSize: Double,
        context: String = "general"
    ) -> NSAttributedString {
        guard text.isEmpty == false else { return NSAttributedString(string: text) }

        let mutable = NSMutableAttributedString(string: text)
        let rubyReadingKey = NSAttributedString.Key("RubyReadingText")
        let rubySizeKey = NSAttributedString.Key("RubyReadingFontSize")
        let nsText = text as NSString
        var appliedCount = 0
        let projectionStart = CFAbsoluteTimeGetCurrent()

        for annotatedSpan in annotatedSpans {
            guard let reading = annotatedSpan.readingKana, annotatedSpan.span.range.location != NSNotFound else { continue }
            guard annotatedSpan.span.range.length > 0 else { continue }
            guard containsKanji(in: annotatedSpan.span.surface) else { continue }

            // Some segmentation outputs isolate the kanji and exclude the following okurigana.
            // If we only project within that kanji-only range, the projector cannot split readings
            // like "だかれ" against the surface "抱かれ" and ends up attaching the full reading
            // to a single glyph, which is prone to CoreText clamping/shift.
            //
            // Expand the projection window to include immediate trailing kana so the projector can
            // properly consume/trim the okurigana portion.
            let originalRange = annotatedSpan.span.range
            guard NSMaxRange(originalRange) <= nsText.length else { continue }
            let projectionRange = extendRangeForwardOverKana(originalRange, in: nsText)
            guard NSMaxRange(projectionRange) <= nsText.length else { continue }
            let spanText = nsText.substring(with: projectionRange)

            let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: projectionRange)

            for segment in segments {
                guard segment.reading.isEmpty == false else { continue }
                mutable.addAttribute(.rubyAnnotation, value: true, range: segment.range)
                mutable.addAttribute(rubyReadingKey, value: segment.reading, range: segment.range)
                mutable.addAttribute(rubySizeKey, value: furiganaSize, range: segment.range)

                applyIntercharacterSpacingIfNeeded(
                    attributedText: mutable,
                    fullText: nsText,
                    baseRange: segment.range,
                    reading: segment.reading,
                    textSize: textSize,
                    furiganaSize: furiganaSize
                )
                appliedCount += 1
            }
        }

        _ = elapsedMilliseconds(since: projectionStart)
        // log("[\(context)] Projected ruby for \(appliedCount) segments in (projectionDuration) ms.")
        return mutable.copy() as? NSAttributedString ?? NSAttributedString(string: text)
    }

    private static func containsKanji(in text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func extendRangeForwardOverKana(_ range: NSRange, in text: NSString) -> NSRange {
        guard range.location != NSNotFound, range.length > 0 else { return range }
        let textLength = text.length
        var end = NSMaxRange(range)
        guard end <= textLength else { return range }

        // Keep this conservative to avoid accidentally pulling in the next token.
        let maxAdditionalComposedChars = 8
        var added = 0

        while end < textLength, added < maxAdditionalComposedChars {
            let composed = text.rangeOfComposedCharacterSequence(at: end)
            guard composed.location != NSNotFound, composed.length > 0 else { break }
            guard NSMaxRange(composed) <= textLength else { break }

            let s = text.substring(with: composed)
            guard let ch = s.first else { break }
            if ch.isWhitespace || ch.isNewline { break }
            if isKana(ch) {
                end = NSMaxRange(composed)
                added += 1
            } else {
                break
            }
        }

        return NSRange(location: range.location, length: end - range.location)
    }

    private static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x3040...0x309F).contains($0.value) || (0x30A0...0x30FF).contains($0.value)
        }
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func makeRubyAnnotation(text: String, textSize _: Double, furiganaSize: Double) -> CTRubyAnnotation? {
        guard text.isEmpty == false else { return nil }
        let rubyFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, furiganaSize)))
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: rubyFont] as CFDictionary
        log("[ruby] attributes: \(String(describing: attributes))")
        return CTRubyAnnotationCreateWithAttributes(
            .center,
            // Prefer expanding the base rather than allowing ruby to overhang the base.
            .none,
            .before,
            text as CFString,
            attributes
        )
    }

    private static func applyIntercharacterSpacingIfNeeded(
        attributedText: NSMutableAttributedString,
        fullText: NSString,
        baseRange: NSRange,
        reading: String,
        textSize: Double,
        furiganaSize: Double
    ) {
        guard baseRange.location != NSNotFound, baseRange.length > 0 else { return }
        guard NSMaxRange(baseRange) <= fullText.length else { return }

        let baseString = fullText.substring(with: baseRange)
        guard containsKanji(in: baseString) else { return }

        // Approximate traditional furigana handling: when ruby is wider than the base,
        // widen the space around the base (without inserting actual characters).
        // We do this by adding kerning between the base and its neighbors.
        let baseFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, textSize)))
        let rubyFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, furiganaSize)))

        let baseWidth = (baseString as NSString).size(withAttributes: [.font: baseFont]).width
        let rubyWidth = (reading as NSString).size(withAttributes: [.font: rubyFont]).width
        let rawExtra = rubyWidth - baseWidth
        guard rawExtra > 0.5 else { return }

        // Avoid creating huge gaps for very long readings.
        let cappedExtra = min(rawExtra, baseFont.pointSize * 1.75)

        let prevIndex = baseRange.location - 1
        let nextIndex = NSMaxRange(baseRange)
        let lastBaseIndex = NSMaxRange(baseRange) - 1
        guard lastBaseIndex >= 0 else { return }

        let canAddBefore: Bool = {
            guard prevIndex >= 0, prevIndex < fullText.length else { return false }
            let prevChar = fullText.character(at: prevIndex)
            return Character(UnicodeScalar(prevChar)!).isNewline == false
        }()

        let canAddAfter: Bool = {
            // If the base ends at the end of the string, we can still add trailing kern.
            guard nextIndex <= fullText.length else { return false }
            if nextIndex == fullText.length { return true }
            let nextChar = fullText.character(at: nextIndex)
            return Character(UnicodeScalar(nextChar)!).isNewline == false
        }()

        // Distribute the extra width as "space" before and after the headword.
        // (Implemented via kerning so we don't insert characters and shift ranges.)
        let beforeAmount: Double
        let afterAmount: Double
        switch (canAddBefore, canAddAfter) {
        case (true, true):
            beforeAmount = cappedExtra / 2.0
            afterAmount = cappedExtra / 2.0
        case (true, false):
            beforeAmount = cappedExtra
            afterAmount = 0
        case (false, true):
            beforeAmount = 0
            afterAmount = cappedExtra
        case (false, false):
            return
        }

        if beforeAmount > 0, canAddBefore {
            // Space before headword: add kerning after the previous character.
            let existingPrevKern = (attributedText.attribute(.kern, at: prevIndex, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
            attributedText.addAttribute(.kern, value: NSNumber(value: existingPrevKern + beforeAmount), range: NSRange(location: prevIndex, length: 1))
        }

        if afterAmount > 0, canAddAfter {
            // Space after headword: add kerning after the last character in the base range.
            let existingLastKern = (attributedText.attribute(.kern, at: lastBaseIndex, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
            attributedText.addAttribute(.kern, value: NSNumber(value: existingLastKern + afterAmount), range: NSRange(location: lastBaseIndex, length: 1))
        }
    }

    private static func describe(spans: [TextSpan]) -> String {
        spans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
    }
}

private extension FuriganaAttributedTextBuilder {
    private static func applySpanOverrides(
        spans: [TextSpan],
        overrides: [ReadingOverride],
        text: String
    ) -> [TextSpan] {
        guard overrides.isEmpty == false else { return spans }
        let nsText = text as NSString
        var boundedOverrides: [TextSpan] = []
        var boundedRanges: [NSRange] = []
        let textLength = nsText.length
        for override in overrides {
            let rawRange = override.nsRange
            guard rawRange.location != NSNotFound, rawRange.length > 0 else { continue }
            guard rawRange.location < textLength else { continue }
            let cappedEnd = min(NSMaxRange(rawRange), textLength)
            guard cappedEnd > rawRange.location else { continue }
            let normalized = NSRange(location: rawRange.location, length: cappedEnd - rawRange.location)
            guard let trimmed = Self.trimmedRange(from: normalized, in: nsText) else { continue }
            let newlineSegments = Self.splitRangeByNewlines(trimmed, in: nsText)
            for segment in newlineSegments {
                guard let clamped = Self.trimmedRange(from: segment, in: nsText) else { continue }
                guard clamped.length > 0 else { continue }
                let surface = nsText.substring(with: clamped)
                boundedOverrides.append(TextSpan(range: clamped, surface: surface))
                boundedRanges.append(clamped)
            }
        }
        guard boundedOverrides.isEmpty == false else { return spans }
        var filtered = spans.filter { span in
            boundedRanges.contains { NSIntersectionRange($0, span.range).length > 0 } == false
        }
        filtered.append(contentsOf: boundedOverrides)
        filtered.sort { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                return lhs.range.length < rhs.range.length
            }
            return lhs.range.location < rhs.range.location
        }
        return filtered
    }

    private static func trimmedRange(from range: NSRange, in text: NSString) -> NSRange? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var start = range.location
        var end = NSMaxRange(range)
        let whitespace = CharacterSet.whitespacesAndNewlines
        while start < end {
            guard let scalar = UnicodeScalar(text.character(at: start)) else { break }
            if whitespace.contains(scalar) {
                start += 1
            } else {
                break
            }
        }
        while end > start {
            guard let scalar = UnicodeScalar(text.character(at: end - 1)) else { break }
            if whitespace.contains(scalar) {
                end -= 1
            } else {
                break
            }
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func splitRangeByNewlines(_ range: NSRange, in text: NSString) -> [NSRange] {
        guard range.length > 0 else { return [] }
        var segments: [NSRange] = []
        var segmentStart = range.location
        let upperBound = NSMaxRange(range)
        var index = range.location
        while index < upperBound {
            let unit = text.character(at: index)
            if let scalar = UnicodeScalar(unit), CharacterSet.newlines.contains(scalar) {
                if index > segmentStart {
                    segments.append(NSRange(location: segmentStart, length: index - segmentStart))
                }
                segmentStart = index + 1
            }
            index += 1
        }
        if segmentStart < upperBound {
            segments.append(NSRange(location: segmentStart, length: upperBound - segmentStart))
        }
        return segments.isEmpty ? [range] : segments
    }

    private static func applyReadingOverrides(
        _ annotated: [AnnotatedSpan],
        overrides: [ReadingOverride]
    ) -> [AnnotatedSpan] {
        let mapping: [OverrideKey: String] = overrides.reduce(into: [:]) { partialResult, override in
            guard let kana = override.userKana, kana.isEmpty == false else { return }
            let key = OverrideKey(location: override.rangeStart, length: override.rangeLength)
            partialResult[key] = kana
        }
        guard mapping.isEmpty == false else { return annotated }
        return annotated.map { span in
            let key = OverrideKey(location: span.span.range.location, length: span.span.range.length)
            if let kana = mapping[key] {
                return AnnotatedSpan(span: span.span, readingKana: kana, lemmaCandidates: span.lemmaCandidates)
            }
            return span
        }
    }

    private struct OverrideKey: Hashable {
        let location: Int
        let length: Int
    }
}
