import XCTest
@testable import kyouku

@MainActor
final class FuriganaPipelineServiceTests: XCTestCase {
    private func makeInput(
        text: String,
        showFurigana: Bool,
        recomputeSpans: Bool,
        existingSpans: [AnnotatedSpan]? = nil,
        existingSemanticSpans: [SemanticSpan] = [],
        knownWordSurfaceKeys: Set<String> = []
    ) -> FuriganaPipelineService.Input {
        FuriganaPipelineService.Input(
            text: text,
            showFurigana: showFurigana,
            needsTokenHighlights: false,
            textSize: 17,
            furiganaSize: 9,
            recomputeSpans: recomputeSpans,
            existingSpans: existingSpans,
            existingSemanticSpans: existingSemanticSpans,
            amendedSpans: nil,
            hardCuts: [],
            readingOverrides: [],
            context: "FuriganaPipelineServiceTests",
            padHeadwordSpacing: false,
            knownWordSurfaceKeys: knownWordSurfaceKeys
        )
    }

    func testSkipsWhenNoConsumersNeedSpans() async {
        let service = FuriganaPipelineService()
        let placeholderSpan = AnnotatedSpan(
            span: TextSpan(range: NSRange(location: 0, length: 1), surface: "星"),
            readingKana: "ほし"
        )
        let placeholderSemantic = SemanticSpan(
            range: placeholderSpan.span.range,
            surface: placeholderSpan.span.surface,
            sourceSpanIndices: 0..<1,
            readingKana: placeholderSpan.readingKana
        )
        let input = makeInput(
            text: "星",
            showFurigana: false,
            recomputeSpans: false,
            existingSpans: [placeholderSpan],
            existingSemanticSpans: [placeholderSemantic]
        )

        let result = await service.render(input)
        XCTAssertEqual(result.spans, [placeholderSpan])
        XCTAssertNil(result.attributedString)
    }

    func testProducesAnnotatedTextWhenEnabled() async {
        let service = FuriganaPipelineService()
        let text = "星を見る"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        XCTAssertNotNil(result.spans)
        XCTAssertEqual(result.attributedString?.string, text)
        XCTAssertEqual(result.attributedString?.length, text.utf16.count)
    }

    func testPasteStyleOkuriganaDoesNotOverTrimInsideReading() async {
        // Regression: In the paste area, "私たち" was projecting "わ" over 私.
        // The expected kanji reading chunk is "わたし".
        let service = FuriganaPipelineService()
        let text = "私たち"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        var effectiveRange = NSRange(location: 0, length: 0)
        let reading = attributed.attribute(key, at: 0, effectiveRange: &effectiveRange) as? String
        XCTAssertEqual(reading, "わたし")
    }

    func testKnownWordRubySuppressionRemovesRuby() async {
        let service = FuriganaPipelineService()
        let text = "星を見る"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true,
            knownWordSurfaceKeys: ["星"]
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        let reading = attributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertNil(reading)
    }
}
