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

        logger.info("[\(context, privacy: .public)] Starting furigana build for \(text.count, privacy: .public) characters.")
        let buildStart = CFAbsoluteTimeGetCurrent()

        // Stage 1: Trie-backed segmentation.
        let segmentationStart = CFAbsoluteTimeGetCurrent()
        let segmented = try await SegmentationService.shared.segment(text: text)
        let segmentationDuration = elapsedMilliseconds(since: segmentationStart)
        logger.info("[\(context, privacy: .public)] Segmentation spans found: \(segmented.count, privacy: .public) in \(segmentationDuration, privacy: .public) ms.")

        // Stage 2: MeCab reading attachment with caching.
        let attachmentStart = CFAbsoluteTimeGetCurrent()
        let annotated = await SpanReadingAttacher().attachReadings(text: text, spans: segmented)
        let attachmentDuration = elapsedMilliseconds(since: attachmentStart)
        logger.info("[\(context, privacy: .public)] Annotated spans ready for projection: \(annotated.count, privacy: .public) in \(attachmentDuration, privacy: .public) ms.")

        let mutable = NSMutableAttributedString(string: text)
        let rubyKey = NSAttributedString.Key(rawValue: kCTRubyAnnotationAttributeName as String)
        let nsText = text as NSString
        var appliedCount = 0
        let projectionStart = CFAbsoluteTimeGetCurrent()

        for annotatedSpan in annotated {
            guard let reading = annotatedSpan.readingKana, annotatedSpan.span.range.location != NSNotFound else { continue }
            guard annotatedSpan.span.range.length > 0 else { continue }
            guard containsKanji(in: annotatedSpan.span.surface) else { continue }
            let range = annotatedSpan.span.range
            guard NSMaxRange(range) <= nsText.length else { continue }
            let spanText = nsText.substring(with: range)

            // Stage 3: Projection of per-span ruby segments.
            let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: range)

            for segment in segments {
                if let annotation = makeRubyAnnotation(text: segment.reading, textSize: textSize, furiganaSize: furiganaSize) {
                    mutable.addAttribute(rubyKey, value: annotation, range: segment.range)
                    appliedCount += 1
                }
            }
        }

        let projectionDuration = elapsedMilliseconds(since: projectionStart)
        let totalDuration = elapsedMilliseconds(since: buildStart)

        logger.info("[\(context, privacy: .public)] Finished furigana build. Applied ruby to \(appliedCount, privacy: .public) spans in \(projectionDuration, privacy: .public) ms (total \(totalDuration, privacy: .public) ms).")
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
