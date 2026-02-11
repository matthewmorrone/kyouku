import XCTest
@testable import kyouku

final class FuriganaPipelineServiceTests: XCTestCase {
    private func makeInput(
        text: String,
        showFurigana: Bool,
        recomputeSpans: Bool,
        existingSpans: [AnnotatedSpan]? = nil,
        knownWordSurfaceKeys: Set<String> = [],
        selectedRange: NSRange? = nil
    ) -> FuriganaPipelineService.Input {
        FuriganaPipelineService.Input(
            text: text,
            showFurigana: showFurigana,
            needsTokenHighlights: false,
            textSize: 17,
            furiganaSize: 9,
            recomputeSpans: recomputeSpans,
            existingSpans: existingSpans,
            existingSemanticSpans: [],
            amendedSpans: nil,
            hardCuts: [],
            readingOverrides: [],
            context: "FuriganaPipelineServiceTests",
            padHeadwordSpacing: false,
            knownWordSurfaceKeys: knownWordSurfaceKeys,
            selectedRange: selectedRange
        )
    }

    func testSkipsWhenNoConsumersNeedSpans() async {
        let service = FuriganaPipelineService()
        let placeholderSpan = AnnotatedSpan(
            span: TextSpan(range: NSRange(location: 0, length: 1), surface: "星"),
            readingKana: "ほし"
        )
        let input = makeInput(
            text: "星",
            showFurigana: false,
            recomputeSpans: false,
            existingSpans: [placeholderSpan]
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
        let reading = attributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(reading, "わたし")
    }

    func testKnownWordRubySuppressionRemovesRubyWhenNotSelected() async {
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

    func testKnownWordRubySuppressionKeepsRubyWhenSelected() async {
        let service = FuriganaPipelineService()
        let text = "星を見る"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true,
            knownWordSurfaceKeys: ["星"],
            selectedRange: NSRange(location: 0, length: 1)
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        let reading = attributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertNotNil(reading)
    }
}
