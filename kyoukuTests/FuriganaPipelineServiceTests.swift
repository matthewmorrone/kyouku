import XCTest
@testable import kyouku

final class FuriganaPipelineServiceTests: XCTestCase {
    func testSkipsWhenNoConsumersNeedSpans() async {
        let service = FuriganaPipelineService()
        let placeholderSpan = AnnotatedSpan(
            span: TextSpan(range: NSRange(location: 0, length: 1), surface: "星"),
            readingKana: "ほし"
        )
        let input = FuriganaPipelineService.Input(
            text: "星",
            showFurigana: false,
            needsTokenHighlights: false,
            textSize: 17,
            furiganaSize: 9,
            recomputeSpans: false,
            existingSpans: [placeholderSpan],
            overrides: [],
            context: "FuriganaPipelineServiceTests"
        )

        let result = await service.render(input)
        XCTAssertEqual(result.spans, [placeholderSpan])
        XCTAssertNil(result.attributedString)
    }

    func testProducesAnnotatedTextWhenEnabled() async {
        let service = FuriganaPipelineService()
        let text = "星を見る"
        let input = FuriganaPipelineService.Input(
            text: text,
            showFurigana: true,
            needsTokenHighlights: false,
            textSize: 17,
            furiganaSize: 9,
            recomputeSpans: true,
            existingSpans: nil,
            overrides: [],
            context: "FuriganaPipelineServiceTests"
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
        let input = FuriganaPipelineService.Input(
            text: text,
            showFurigana: true,
            needsTokenHighlights: false,
            textSize: 17,
            furiganaSize: 9,
            recomputeSpans: true,
            existingSpans: nil,
            overrides: [],
            context: "FuriganaPipelineServiceTests"
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        let reading = attributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(reading, "わたし")
    }
}
