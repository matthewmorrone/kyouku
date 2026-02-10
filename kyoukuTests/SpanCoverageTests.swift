import XCTest
@testable import kyouku

final class SpanCoverageTests: XCTestCase {
    func testCoverageGapsIgnoresWhitespaceOnlyGaps() async throws {
        let text = "a b"
        let nsText = text as NSString
        let spans: [TextSpan] = [
            TextSpan(range: NSRange(location: 0, length: 1), surface: nsText.substring(with: NSRange(location: 0, length: 1)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 2, length: 1), surface: nsText.substring(with: NSRange(location: 2, length: 1)), isLexiconMatch: false)
        ]

        let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
            text: text,
            context: "SpanCoverageTests",
            baseSpans: spans
        )
        let ranges = stage2.annotatedSpans.map(\.span.range)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1)])
    }

    func testCoverageGapsDetectsMissingNonWhitespace() async throws {
        let text = "ab"
        let nsText = text as NSString
        let spans: [TextSpan] = [
            TextSpan(range: NSRange(location: 0, length: 1), surface: nsText.substring(with: NSRange(location: 0, length: 1)), isLexiconMatch: false)
        ]

        let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(
            text: text,
            context: "SpanCoverageTests",
            baseSpans: spans
        )
        let ranges = stage2.annotatedSpans.map(\.span.range)
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)])
    }
}
