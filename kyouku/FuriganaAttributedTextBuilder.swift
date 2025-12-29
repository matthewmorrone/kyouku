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
        var spanDump = segmented
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
        // log("[\(context)] segmented spans: [\(spanDump)]")
        let adjustedSpans = applySpanOverrides(
            spans: segmented,
            overrides: overrides,
            text: text
        )
        spanDump = adjustedSpans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
        // log("[\(context)] adjusted spans: [\(spanDump)]")

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
        let rubyKey = NSAttributedString.Key(rawValue: kCTRubyAnnotationAttributeName as String)
        let nsText = text as NSString
        var appliedCount = 0
        let projectionStart = CFAbsoluteTimeGetCurrent()

        for annotatedSpan in annotatedSpans {
            guard let reading = annotatedSpan.readingKana, annotatedSpan.span.range.location != NSNotFound else { continue }
            guard annotatedSpan.span.range.length > 0 else { continue }
            guard containsKanji(in: annotatedSpan.span.surface) else { continue }
            let range = annotatedSpan.span.range
            guard NSMaxRange(range) <= nsText.length else { continue }
            let spanText = nsText.substring(with: range)

            let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: range)

            for segment in segments {
                if let annotation = makeRubyAnnotation(text: segment.reading, textSize: textSize, furiganaSize: furiganaSize) {
                    mutable.addAttribute(rubyKey, value: annotation, range: segment.range)
                    mutable.addAttribute(.rubyAnnotation, value: true, range: segment.range)
                    appliedCount += 1
                }
            }
        }

        _ = elapsedMilliseconds(since: projectionStart)
        // log("[\(context)] Projected ruby for \(appliedCount) segments in (projectionDuration) ms.")
        return mutable.copy() as? NSAttributedString ?? NSAttributedString(string: text)
    }

    private static func containsKanji(in text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func makeRubyAnnotation(text: String, textSize _: Double, furiganaSize: Double) -> CTRubyAnnotation? {
        guard text.isEmpty == false else { return nil }
        let rubyFont = UIFont.systemFont(ofSize: CGFloat(max(1.0, furiganaSize)))
        let attributes = [kCTFontAttributeName as NSAttributedString.Key: rubyFont] as CFDictionary
        return CTRubyAnnotationCreateWithAttributes(
            .center,
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
