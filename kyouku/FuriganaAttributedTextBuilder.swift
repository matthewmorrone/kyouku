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
        log("[\(context)] segmented spans: [\(spanDump)]")
        let adjustedSpans = applySpanOverrides(
            spans: segmented,
            overrides: overrides,
            text: text
        )
        spanDump = adjustedSpans
            .map { span in "\(span.range.location)-\(NSMaxRange(span.range)) «\(span.surface)»" }
            .joined(separator: ", ")
        log("[\(context)] adjusted spans: [\(spanDump)]")

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
            .auto,
            .before,
            text as CFString,
            attributes
        )
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
        let boundedOverrides: [TextSpan] = overrides.compactMap { override in
            let range = override.nsRange
            guard range.location != NSNotFound, range.length > 0 else { return nil }
            guard NSMaxRange(range) <= nsText.length else { return nil }
            let surface = nsText.substring(with: range)
            return TextSpan(range: range, surface: surface)
        }
        guard boundedOverrides.isEmpty == false else { return spans }
        var filtered = spans.filter { span in
            overrides.contains { $0.overlaps(span.range) }
                == false
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
