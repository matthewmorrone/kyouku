import XCTest
@testable import kyouku

final class LookupNormalizationPipelineTests: XCTestCase {
    func testHalfwidthKatakanaBuildsNormalizedLookupAndTapLookupSucceeds() async throws {
        let surface = "ｶﾞｯｺｳ"
        let nsSurface = surface as NSString
        let selectedRange = NSRange(location: 0, length: nsSurface.length)
        let tokenSpans = [TextSpan(range: selectedRange, surface: surface, isLexiconMatch: false)]

        let candidates = SelectionSpanResolver.candidates(
            selectedRange: selectedRange,
            tokenSpans: tokenSpans,
            text: nsSurface
        )

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(candidates[0].displayKey, surface)
        XCTAssertEqual(candidates[0].lookupKey, "ガッコウ")

        let rows = try await DictionarySQLiteStore.shared.lookup(term: candidates[0].lookupKey, limit: 10, mode: .japanese)
        XCTAssertFalse(rows.isEmpty)
    }

    func testIterationMarkExpandsForLookupAndSegmentationDoesNotSplitAtMark() async throws {
        let surface = "さゝやく"
        XCTAssertEqual(normalizeForLookup(surface), "ささやく")

        let spans = try await SegmentationService.shared.segment(text: surface)
        let forbiddenBoundary = 2 // boundary immediately after ゝ in UTF-16
        XCTAssertFalse(spans.contains(where: { NSMaxRange($0.range) == forbiddenBoundary }))
    }

    func testCombiningDakutenNormalizesToComposedHiragana() {
        let surface = "がくせい"
        XCTAssertEqual(normalizeForLookup(surface), "がくせい")
    }
}
