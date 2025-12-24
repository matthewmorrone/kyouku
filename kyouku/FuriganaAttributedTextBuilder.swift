import Foundation
import UIKit
import CoreText
import OSLog

enum FuriganaAttributedTextBuilder {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "kyouku", category: "FuriganaBuilder")

    static func build(
        text: String,
        textSize: Double,
        furiganaSize: Double,
        context: String = "general"
    ) async throws -> NSAttributedString {
        guard text.isEmpty == false else {
            logger.info("[\(context, privacy: .public)] Skipping build because the input text is empty.")
            return NSAttributedString(string: text)
        }

        let buildStart = CFAbsoluteTimeGetCurrent()
        let annotated = try await computeAnnotatedSpans(text: text, context: context)
        let attributed = project(
            text: text,
            annotatedSpans: annotated,
            textSize: textSize,
            furiganaSize: furiganaSize,
            context: context
        )
        let totalDuration = elapsedMilliseconds(since: buildStart)
        logger.info("[\(context, privacy: .public)] Finished furigana build in \(totalDuration, privacy: .public) ms.")
        return attributed
    }

    static func computeAnnotatedSpans(
        text: String,
        context: String = "general"
    ) async throws -> [AnnotatedSpan] {
        guard text.isEmpty == false else {
            logger.info("[\(context, privacy: .public)] Skipping span computation because the input text is empty.")
            return []
        }

        logger.info("[\(context, privacy: .public)] Starting furigana span computation for \(text.count, privacy: .public) characters.")
        let start = CFAbsoluteTimeGetCurrent()

        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let segmented = try await SegmentationService.shared.segment(text: text)
        let segmentationDuration = elapsedMilliseconds(since: segmentationStart)
        logger.info("[\(context, privacy: .public)] Segmentation spans found: \(segmented.count, privacy: .public) in \(segmentationDuration, privacy: .public) ms.")

        let attachmentStart = CFAbsoluteTimeGetCurrent()
        let annotated = await SpanReadingAttacher().attachReadings(text: text, spans: segmented)
        let attachmentDuration = elapsedMilliseconds(since: attachmentStart)
        logger.info("[\(context, privacy: .public)] Annotated spans ready for projection: \(annotated.count, privacy: .public) in \(attachmentDuration, privacy: .public) ms.")

        let totalDuration = elapsedMilliseconds(since: start)
        logger.info("[\(context, privacy: .public)] Completed span computation in \(totalDuration, privacy: .public) ms.")
        return annotated
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

        let projectionDuration = elapsedMilliseconds(since: projectionStart)
        // logger.info("[\(context, privacy: .public)] Projected ruby for \(appliedCount, privacy: .public) segments in \(projectionDuration, privacy: .public) ms.")
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
            .auto,
            .auto,
            .before,
            text as CFString,
            attributes
        )
    }
}
