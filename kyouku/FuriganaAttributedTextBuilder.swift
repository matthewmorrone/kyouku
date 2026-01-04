import Foundation
import UIKit
import CoreText
import OSLog

enum FuriganaAttributedTextBuilder {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "FuriganaBuilder")
    private static let rubyTraceLogger = DiagnosticsLogging.logger(.furiganaRubyTrace)
    private static func log(_ message: String, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
        guard DiagnosticsLogging.isEnabled(.furigana) else { return }
        logger.info("[\(file):\(line)] \(function): \(message)")
    }

    static func build(
        text: String,
        textSize: Double,
        furiganaSize: Double,
        context: String = "general",
        tokenBoundaries: [Int] = [],
        readingOverrides: [ReadingOverride] = []
    ) async throws -> NSAttributedString {
        guard text.isEmpty == false else {
            log("[\(context)] Skipping build because the input text is empty.")
            return NSAttributedString(string: text)
        }

        let buildStart = CFAbsoluteTimeGetCurrent()
        let annotated = try await computeAnnotatedSpans(
            text: text,
            context: context,
            tokenBoundaries: tokenBoundaries,
            readingOverrides: readingOverrides
        )
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
        tokenBoundaries: [Int] = [],
        readingOverrides: [ReadingOverride] = [],
        baseSpans: [TextSpan]? = nil
    ) async throws -> [AnnotatedSpan] {
        guard text.isEmpty == false else {
            log("[\(context)] Skipping span computation because the input text is empty.")
            return []
        }

        log("[\(context)] Starting furigana span computation for \(text.count) characters.")
        let start = CFAbsoluteTimeGetCurrent()

        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let segmented: [TextSpan]
        if let baseSpans {
            segmented = baseSpans
        } else {
            segmented = try await SegmentationService.shared.segment(text: text)
        }
        let nsText = text as NSString
        let adjustedSpans = normalizeCoverage(spans: segmented, text: nsText)
        let gaps = coverageGaps(spans: adjustedSpans, text: text)
        if gaps.isEmpty == false {
            log("[\(context)] Coverage gaps detected after normalization: \(gaps)")
        }
        let segmentationDuration = elapsedMilliseconds(since: segmentationStart)
        log("[\(context)] Segmentation spans ready: \(adjustedSpans.count) in \(segmentationDuration) ms.")

        let attachmentStart = CFAbsoluteTimeGetCurrent()
        let annotated = await SpanReadingAttacher().attachReadings(text: text, spans: adjustedSpans)
        let resolvedAnnotated = applyReadingOverrides(
            annotated,
            overrides: readingOverrides
        )
        let attachmentDuration = elapsedMilliseconds(since: attachmentStart)
        log("[\(context)] Annotated spans ready for projection: \(resolvedAnnotated.count) in \(attachmentDuration) ms.")

        let totalDuration = elapsedMilliseconds(since: start)
        log("[\(context)] Completed span computation in \(totalDuration) ms.")
        return resolvedAnnotated
    }

    static func coverageGaps(spans: [TextSpan], text: String) -> [NSRange] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }
        let bounds = NSRange(location: 0, length: length)

        let sorted: [TextSpan] = spans
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .map { span in
                let clampedRange = NSIntersectionRange(span.range, bounds)
                let clampedSurface = clampedRange.length > 0 ? nsText.substring(with: clampedRange) : ""
                return TextSpan(range: clampedRange, surface: clampedSurface, isLexiconMatch: span.isLexiconMatch)
            }
            .filter { $0.range.length > 0 }
            .sorted { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }

        var gaps: [NSRange] = []
        gaps.reserveCapacity(8)
        var cursor = 0

        func appendGapIfNeeded(from start: Int, to end: Int) {
            guard end > start else { return }
            let gap = NSRange(location: start, length: end - start)
            guard containsNonWhitespace(in: gap, text: nsText) else { return }
            gaps.append(gap)
        }

        for span in sorted {
            let spanStart = span.range.location
            let spanEnd = NSMaxRange(span.range)
            if spanStart > cursor {
                appendGapIfNeeded(from: cursor, to: spanStart)
            }
            cursor = max(cursor, spanEnd)
            if cursor >= length { break }
        }

        if cursor < length {
            appendGapIfNeeded(from: cursor, to: length)
        }

        return gaps
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

        for (spanIndex, annotatedSpan) in annotatedSpans.enumerated() {
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

            // Never extend across token/span boundaries. If the next span begins immediately after
            // this one (e.g. particle "に"), pulling it into the projection window causes
            // overzealous trimming (e.g. custom reading "くに" -> "く").
            let nextBoundary: Int = {
                guard spanIndex + 1 < annotatedSpans.count else { return nsText.length }
                let next = annotatedSpans[spanIndex + 1].span.range
                return next.location == NSNotFound ? nsText.length : max(0, min(nsText.length, next.location))
            }()

            let projectionRange = extendRangeForwardOverKana(originalRange, in: nsText, maxEnd: nextBoundary)
            guard NSMaxRange(projectionRange) <= nsText.length else { continue }
            let spanText = nsText.substring(with: projectionRange)

            let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: projectionRange)

            for segment in segments {
                guard segment.reading.isEmpty == false else { continue }
                mutable.addAttribute(.rubyAnnotation, value: true, range: segment.range)
                mutable.addAttribute(rubyReadingKey, value: segment.reading, range: segment.range)
                mutable.addAttribute(rubySizeKey, value: furiganaSize, range: segment.range)

                if DiagnosticsLogging.isEnabled(.furiganaRubyTrace) {
                    let headword = nsText.substring(with: segment.range)
                    Self.rubyTraceLogger.info(
                        "ruby headword='\(headword, privacy: .public)' reading='\(segment.reading, privacy: .public)' commonKanaRemoved='\(segment.commonKanaRemoved, privacy: .public)'"
                    )
                }
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

    private static func extendRangeForwardOverKana(_ range: NSRange, in text: NSString, maxEnd: Int) -> NSRange {
        guard range.location != NSNotFound, range.length > 0 else { return range }
        let textLength = min(text.length, max(0, maxEnd))
        var end = NSMaxRange(range)
        guard end <= textLength else { return range }

        // If the span already includes trailing kana (e.g. "香り"), do NOT extend further.
        // Extending would pull in kana from the next token/particle (e.g. "で"), which can
        // prevent proper okurigana removal.
        let lastIndex = max(range.location, end - 1)
        let lastComposed = text.rangeOfComposedCharacterSequence(at: lastIndex)
        if lastComposed.location != NSNotFound, lastComposed.length > 0, NSMaxRange(lastComposed) <= textLength {
            let lastString = text.substring(with: lastComposed)
            if let lastChar = lastString.first, isKana(lastChar) {
                return range
            }
        }

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

    private static func describe(spans: [TextSpan]) -> String {
        spans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
    }
}

private extension FuriganaAttributedTextBuilder {
    private static func normalizeCoverage(spans: [TextSpan], text: NSString) -> [TextSpan] {
        let length = text.length
        guard length > 0 else { return [] }
        let bounds = NSRange(location: 0, length: length)

        let sorted: [TextSpan] = spans
            .filter { $0.range.location != NSNotFound && $0.range.length > 0 }
            .map { span in
                let clampedRange = NSIntersectionRange(span.range, bounds)
                let clampedSurface = clampedRange.length > 0 ? text.substring(with: clampedRange) : ""
                return TextSpan(range: clampedRange, surface: clampedSurface, isLexiconMatch: span.isLexiconMatch)
            }
            .filter { $0.range.length > 0 }
            .sorted { lhs, rhs in
                if lhs.range.location == rhs.range.location {
                    return lhs.range.length < rhs.range.length
                }
                return lhs.range.location < rhs.range.location
            }

        var normalized: [TextSpan] = []
        normalized.reserveCapacity(sorted.count + 8)
        var cursor = 0

        func appendGapIfNeeded(from start: Int, to end: Int) {
            guard end > start else { return }
            let gap = NSRange(location: start, length: end - start)
            guard containsNonWhitespace(in: gap, text: text) else { return }
            let surface = text.substring(with: gap)
            normalized.append(TextSpan(range: gap, surface: surface, isLexiconMatch: false))
        }

        for span in sorted {
            let spanStart = span.range.location
            let spanEnd = NSMaxRange(span.range)
            if spanStart > cursor {
                appendGapIfNeeded(from: cursor, to: spanStart)
                normalized.append(span)
                cursor = max(cursor, spanEnd)
                continue
            }
            if spanEnd <= cursor {
                continue
            }
            // Overlap: trim leading portion so coverage stays contiguous.
            let trimmedRange = NSRange(location: cursor, length: spanEnd - cursor)
            let surface = text.substring(with: trimmedRange)
            normalized.append(TextSpan(range: trimmedRange, surface: surface, isLexiconMatch: span.isLexiconMatch))
            cursor = spanEnd
        }

        if cursor < length {
            appendGapIfNeeded(from: cursor, to: length)
        }

        return normalized
    }

    private static func containsNonWhitespace(in range: NSRange, text: NSString) -> Bool {
        guard range.length > 0 else { return false }
        let substring = text.substring(with: range)
        return substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
                return AnnotatedSpan(span: span.span, readingKana: kana, lemmaCandidates: span.lemmaCandidates, partOfSpeech: span.partOfSpeech)
            }
            return span
        }
    }

    private struct OverrideKey: Hashable {
        let location: Int
        let length: Int
    }
}
