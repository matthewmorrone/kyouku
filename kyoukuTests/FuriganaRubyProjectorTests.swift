import XCTest
@testable import kyouku

final class FuriganaRubyProjectorTests: XCTestCase {
    func testSingleKanjiKeepsFullReadingAfterOkuriganaRemoval() {
        let spanText = "占う"
        let reading = "うらな"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.reading, "うらな")
    }

    func testMultiKanjiCompoundKeepsGroupReading() {
        let spanText = "過去"
        let reading = "かこ"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.reading, "かこ")
        XCTAssertEqual(segments.first?.range.length, (spanText as NSString).length)
    }

    func testKanjiPlusTrailingKanaProjectsOnlyKanjiReading() {
        let spanText = "時の"
        let reading = "ときの"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.reading, "とき")
        XCTAssertEqual(segments.first?.range, NSRange(location: 0, length: 1))
    }

    func testKatakanaReadingIsNormalizedForKanaBoundaryMatching() {
        let spanText = "時の"
        let reading = "トキノ"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.reading, "とき")
        XCTAssertEqual(segments.first?.range, NSRange(location: 0, length: 1))
    }
}
