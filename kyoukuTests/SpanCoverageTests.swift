import XCTest
@testable import kyouku

final class SpanCoverageTests: XCTestCase {
    func testCoverageGapsIgnoresWhitespaceOnlyGaps() {
        let text = "a b"
        let nsText = text as NSString
        let spans: [TextSpan] = [
            TextSpan(range: NSRange(location: 0, length: 1), surface: nsText.substring(with: NSRange(location: 0, length: 1)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 2, length: 1), surface: nsText.substring(with: NSRange(location: 2, length: 1)), isLexiconMatch: false)
        ]

        let gaps = FuriganaAttributedTextBuilder.coverageGaps(spans: spans, text: text)
        XCTAssertTrue(gaps.isEmpty)
    }

    func testCoverageGapsDetectsMissingNonWhitespace() {
        let text = "ab"
        let nsText = text as NSString
        let spans: [TextSpan] = [
            TextSpan(range: NSRange(location: 0, length: 1), surface: nsText.substring(with: NSRange(location: 0, length: 1)), isLexiconMatch: false)
        ]

        let gaps = FuriganaAttributedTextBuilder.coverageGaps(spans: spans, text: text)
        XCTAssertEqual(gaps, [NSRange(location: 1, length: 1)])
    }
}
