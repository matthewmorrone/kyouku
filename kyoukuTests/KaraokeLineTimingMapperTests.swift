import XCTest
@testable import kyouku

final class KaraokeLineTimingMapperTests: XCTestCase {
    func testLineSegmentsMatchRecognizedLinesInOrder() {
        let lyrics = """
        あいう
        えお
        """

        let recognition = [
            KaraokeRecognitionSegment(text: "あいう", startSeconds: 0.20, durationSeconds: 1.0, confidence: 0.92),
            KaraokeRecognitionSegment(text: "えお", startSeconds: 1.30, durationSeconds: 0.8, confidence: 0.84)
        ]

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: recognition,
            audioDurationSeconds: 2.5
        )

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].textRange.nsRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(segments[0].startSeconds, 0.20, accuracy: 0.001)
        XCTAssertEqual(segments[0].endSeconds, 1.20, accuracy: 0.001)
        XCTAssertEqual(segments[1].textRange.nsRange, NSRange(location: 4, length: 2))
        XCTAssertEqual(segments[1].startSeconds, 1.30, accuracy: 0.001)
        XCTAssertEqual(segments[1].endSeconds, 2.10, accuracy: 0.001)
    }

    func testLineSegmentsFallbackToInterpolationWhenRecognitionIsEmpty() {
        let lyrics = """
        line one

        line two
        line three
        """

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: [],
            audioDurationSeconds: 9.0
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].startSeconds, 3.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].endSeconds, 6.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].startSeconds, 6.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].endSeconds, 9.0, accuracy: 0.001)
    }

    func testUnmatchedMiddleLineInterpolatesBetweenMatchedAnchors() {
        let lyrics = """
        line one
        line two
        line three
        """

        let recognition = [
            KaraokeRecognitionSegment(text: "line one", startSeconds: 0.0, durationSeconds: 2.0, confidence: 0.9),
            KaraokeRecognitionSegment(text: "bridge text", startSeconds: 2.0, durationSeconds: 4.0, confidence: 0.2),
            KaraokeRecognitionSegment(text: "line three", startSeconds: 6.0, durationSeconds: 2.0, confidence: 0.9)
        ]

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: recognition,
            audioDurationSeconds: 8.0
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].startSeconds, 0.0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].startSeconds, 2.0, accuracy: 0.001)
        XCTAssertEqual(segments[1].endSeconds, 6.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].startSeconds, 6.0, accuracy: 0.001)
        XCTAssertEqual(segments[2].endSeconds, 8.0, accuracy: 0.001)
        XCTAssertLessThan(segments[1].confidence, 0.2)
    }
}
