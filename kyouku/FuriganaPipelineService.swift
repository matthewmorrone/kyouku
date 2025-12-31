import Foundation
import OSLog

struct FuriganaPipelineService {
    struct Input {
        let text: String
        let showFurigana: Bool
        let needsTokenHighlights: Bool
        let textSize: Double
        let furiganaSize: Double
        let recomputeSpans: Bool
        let existingSpans: [AnnotatedSpan]?
        let tokenBoundaries: [Int]
        let readingOverrides: [ReadingOverride]
        let context: String
    }

    struct Result {
        let spans: [AnnotatedSpan]?
        let attributedString: NSAttributedString?
    }

    private static let logger = DiagnosticsLogging.logger(.furigana)

    func render(_ input: Input) async -> Result {
        guard input.showFurigana || input.needsTokenHighlights else {
            Self.logger.debug("\(input.context, privacy: .public) skipping pipeline: no consumers require spans.")
            return Result(spans: input.existingSpans, attributedString: nil)
        }
        guard input.text.isEmpty == false else {
            Self.logger.debug("\(input.context, privacy: .public) skipping pipeline: text is empty.")
            return Result(spans: nil, attributedString: nil)
        }

        var spans = input.existingSpans
        if input.recomputeSpans || spans == nil {
            do {
                spans = try await FuriganaAttributedTextBuilder.computeAnnotatedSpans(
                    text: input.text,
                    context: input.context,
                    tokenBoundaries: input.tokenBoundaries,
                    readingOverrides: input.readingOverrides
                )
            } catch {
                Self.logger.error("\(input.context, privacy: .public) span computation failed: \(String(describing: error), privacy: .public)")
                return Result(spans: nil, attributedString: NSAttributedString(string: input.text))
            }
        }

        guard let resolvedSpans = spans else {
            Self.logger.error("\(input.context, privacy: .public) span computation returned nil even after recompute.")
            return Result(spans: nil, attributedString: NSAttributedString(string: input.text))
        }

        let attributed = FuriganaAttributedTextBuilder.project(
            text: input.text,
            annotatedSpans: resolvedSpans,
            textSize: input.textSize,
            furiganaSize: input.furiganaSize,
            context: input.context
        )
        Self.logger.debug("\(input.context, privacy: .public) projected furigana text length=\(attributed.length).")
        return Result(spans: resolvedSpans, attributedString: attributed)
    }
}
