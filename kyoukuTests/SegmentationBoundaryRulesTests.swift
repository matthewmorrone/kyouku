import XCTest
@testable import kyouku

final class SegmentationBoundaryRulesTests: XCTestCase {
    func testGakuseiIsSingleToken() async throws {
        let result = try await FuriganaAttributedTextBuilder.computeStage2(text: "がくせい")
        let surfaces = result.annotatedSpans.map { $0.span.surface }
        XCTAssertEqual(surfaces, ["がくせい"])
    }

    func testSasayakuWithIterationMarkIsSingleToken() async throws {
        let result = try await FuriganaAttributedTextBuilder.computeStage2(text: "さゝやく")
        let surfaces = result.annotatedSpans.map { $0.span.surface }
        XCTAssertEqual(surfaces, ["さゝやく"])
    }

    func testFullAndHalfWidthKatakanaProduceSameTokenCounts() async throws {
        let full = try await FuriganaAttributedTextBuilder.computeStage2(text: "ガッコウ")
        let half = try await FuriganaAttributedTextBuilder.computeStage2(text: "ｶﾞｯｺｳ")
        XCTAssertEqual(full.annotatedSpans.count, half.annotatedSpans.count)
    }

}
