import XCTest
@testable import kyouku

final class SegmentationServiceHiraganaRunTests: XCTestCase {
    func testHiraganaWordIsSingleStage1Span() async throws {
        let spans = try await SegmentationService.shared.segment(text: "がくせい")
        XCTAssertEqual(spans.map(\.surface), ["がくせい"])
    }

    func testIterationMarkWordIsSingleStage1Span() async throws {
        let spans = try await SegmentationService.shared.segment(text: "さゝやく")
        XCTAssertEqual(spans.map(\.surface), ["さゝやく"])
    }
}
