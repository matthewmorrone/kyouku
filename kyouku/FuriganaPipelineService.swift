import Foundation

struct FuriganaPipelineService {
    struct Input {
        let text: String
        let showFurigana: Bool
        let needsTokenHighlights: Bool
        let textSize: Double
        let furiganaSize: Double
        let recomputeSpans: Bool
        let existingSpans: [AnnotatedSpan]?
        let existingSemanticSpans: [SemanticSpan]
        let amendedSpans: [TextSpan]?
        let hardCuts: [Int]
        let readingOverrides: [ReadingOverride]
        let context: String
    }

    struct Result {
        let spans: [AnnotatedSpan]?
        let semanticSpans: [SemanticSpan]
        let attributedString: NSAttributedString?
    }

    func render(_ input: Input) async -> Result {
        guard input.text.isEmpty == false else {
            CustomLogger.shared.debug("\(input.context) skipping pipeline: text is empty.")
            return Result(spans: nil, semanticSpans: [], attributedString: nil)
        }

        var spans = input.existingSpans
        var semantic = input.existingSemanticSpans
        let hasInvalidSemantic = (spans?.isEmpty == false) && semantic.isEmpty
        if input.recomputeSpans || spans == nil || hasInvalidSemantic {
            do {
                let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
                    text: input.text,
                    context: input.context,
                    tokenBoundaries: input.hardCuts,
                    readingOverrides: input.readingOverrides,
                    baseSpans: input.amendedSpans
                )
                spans = stage2.annotatedSpans
                semantic = stage2.semanticSpans
            } catch {
                CustomLogger.shared.error("\(input.context) span computation failed: \(String(describing: error))")
                return Result(spans: nil, semanticSpans: [], attributedString: NSAttributedString(string: input.text))
            }
        }

        guard let resolvedSpans = spans else {
            CustomLogger.shared.error("\(input.context) span computation returned nil even after recompute.")
            return Result(spans: nil, semanticSpans: [], attributedString: NSAttributedString(string: input.text))
        }

        let resolvedSemantic = semantic

        let attributed: NSAttributedString?
        if input.showFurigana {
            let projected = FuriganaAttributedTextBuilder.project(
                text: input.text,
                semanticSpans: resolvedSemantic,
                textSize: input.textSize,
                furiganaSize: input.furiganaSize,
                context: input.context
            )
            CustomLogger.shared.debug("\(input.context) projected furigana text length=\(projected.length).")
            attributed = projected
        } else {
            attributed = nil
        }

        return Result(spans: resolvedSpans, semanticSpans: resolvedSemantic, attributedString: attributed)
    }
}
