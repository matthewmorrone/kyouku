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
        XCTAssertEqual(segments.first?.commonKanaRemoved, "の")
    }

    func testKatakanaReadingIsNormalizedForKanaBoundaryMatching() {
        let spanText = "時の"
        let reading = "トキノ"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.reading, "とき")
        XCTAssertEqual(segments.first?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(segments.first?.commonKanaRemoved, "の")
    }

    func testKanaInSurfaceIsRemovedFromRuby() {
        let spanText = "香り"
        let reading = "かおり"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(segments.first?.reading, "かお")
        XCTAssertEqual(segments.first?.commonKanaRemoved, "り")
    }

    func testReadingFullyMatchesTrailingKanaProducesNoRuby() {
        let spanText = "行く"
        let reading = "く"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 0)
    }

    func testKanjiPlusOkuriganaKeepsLeadingReading() {
        // Regression: ruby should still appear over 言 in "言いた".
        let spanText = "言いた"
        let reading = "いいた"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(segments.first?.reading, "い")
        XCTAssertEqual(segments.first?.commonKanaRemoved, "いた")
    }

    func testDoesNotDropSharedKanaThatIsNotOkurigana() {
        // Regression: in "何気なく" the leading な must not be removed from ruby.
        let spanText = "何気なく"
        let reading = "なにげなく"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(segments.first?.reading, "なにげ")
        XCTAssertEqual(segments.first?.commonKanaRemoved, "なく")
    }

    func testWatashiTachiProjectsWatashiOverWatashiKanji() {
        // Regression: "私たち" should not split "わたし" at the internal "た".
        let spanText = "私たち"
        let reading = "わたしたち"
        let segments = FuriganaRubyProjector.project(spanText: spanText, reading: reading, spanRange: NSRange(location: 0, length: (spanText as NSString).length))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.range, NSRange(location: 0, length: 1))
        XCTAssertEqual(segments.first?.reading, "わたし")
        XCTAssertEqual(segments.first?.commonKanaRemoved, "たち")
    }
}
