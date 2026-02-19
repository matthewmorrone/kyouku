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

    func testLineSegmentsFallbackUsesWeightedInterpolationWhenRecognitionIsEmpty() {
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
        XCTAssertEqual(segments[1].startSeconds, segments[0].endSeconds, accuracy: 0.001)
        XCTAssertEqual(segments[2].startSeconds, segments[1].endSeconds, accuracy: 0.001)
        XCTAssertEqual(segments[2].endSeconds, 9.0, accuracy: 0.001)
        XCTAssertGreaterThan(segments[2].endSeconds - segments[2].startSeconds, segments[0].endSeconds - segments[0].startSeconds)
        XCTAssertGreaterThan(segments[2].endSeconds - segments[2].startSeconds, segments[1].endSeconds - segments[1].startSeconds)
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

    func testDPAlignmentHandlesRepeatedLinesAndMinorMismatch() {
        let lyrics = """
        hello world
        hello world
        final line
        """

        let recognition = [
            KaraokeRecognitionSegment(text: "hello world", startSeconds: 0.0, durationSeconds: 1.5, confidence: 0.95),
            KaraokeRecognitionSegment(text: "bridge", startSeconds: 1.5, durationSeconds: 0.4, confidence: 0.2),
            KaraokeRecognitionSegment(text: "helo world", startSeconds: 1.9, durationSeconds: 1.4, confidence: 0.91),
            KaraokeRecognitionSegment(text: "final line", startSeconds: 3.4, durationSeconds: 1.2, confidence: 0.96)
        ]

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: recognition,
            audioDurationSeconds: 5.0
        )

        XCTAssertEqual(segments.count, 3)
        XCTAssertLessThanOrEqual(segments[0].startSeconds, 0.1)
        XCTAssertGreaterThan(segments[0].endSeconds, 1.0)
        XCTAssertGreaterThan(segments[1].startSeconds, 1.7)
        XCTAssertGreaterThan(segments[1].endSeconds, segments[1].startSeconds)
        XCTAssertGreaterThan(segments[2].startSeconds, segments[1].endSeconds - 0.15)
        XCTAssertGreaterThan(segments[2].endSeconds, 4.2)
    }

    func testTokenAndPhraseSegmentsAreMonotonicAndInsideLineBounds() {
        let lyrics = "君が、好きだよ"
        let recognition = [
            KaraokeRecognitionSegment(text: "君が", startSeconds: 0.2, durationSeconds: 0.9, confidence: 0.9),
            KaraokeRecognitionSegment(text: "好きだよ", startSeconds: 1.2, durationSeconds: 1.8, confidence: 0.88)
        ]

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: recognition,
            audioDurationSeconds: 3.6
        )

        XCTAssertEqual(segments.count, 1)
        let line = segments[0]
        let tokens = try XCTUnwrap(line.tokenSegments)
        let phrases = try XCTUnwrap(line.phraseSegments)

        XCTAssertGreaterThan(tokens.count, 0)
        XCTAssertGreaterThan(phrases.count, 1)

        var tokenCursor = line.startSeconds
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.startSeconds, line.startSeconds - 0.001)
            XCTAssertLessThanOrEqual(token.endSeconds, line.endSeconds + 0.001)
            XCTAssertGreaterThanOrEqual(token.startSeconds, tokenCursor - 0.001)
            XCTAssertGreaterThanOrEqual(token.endSeconds, token.startSeconds)
            tokenCursor = token.endSeconds
            XCTAssertEqual(token.granularity, .token)
        }

        var phraseCursor = line.startSeconds
        for phrase in phrases {
            XCTAssertGreaterThanOrEqual(phrase.startSeconds, line.startSeconds - 0.001)
            XCTAssertLessThanOrEqual(phrase.endSeconds, line.endSeconds + 0.001)
            XCTAssertGreaterThanOrEqual(phrase.startSeconds, phraseCursor - 0.001)
            XCTAssertGreaterThanOrEqual(phrase.endSeconds, phrase.startSeconds)
            phraseCursor = phrase.endSeconds
            XCTAssertEqual(phrase.granularity, .phrase)
        }
    }

    func testLowConfidenceNoisyAnchorsAreSmoothedWithDurationPriors() {
        let lyrics = """
        aaaa
        bbbb
        cccc
        dddd
        """

        let recognition = [
            KaraokeRecognitionSegment(text: "aaaa", startSeconds: 0.0, durationSeconds: 0.8, confidence: 0.22),
            KaraokeRecognitionSegment(text: "bbbb", startSeconds: 2.60, durationSeconds: 0.1, confidence: 0.14),
            KaraokeRecognitionSegment(text: "cccc", startSeconds: 2.72, durationSeconds: 0.1, confidence: 0.13),
            KaraokeRecognitionSegment(text: "dddd", startSeconds: 3.95, durationSeconds: 0.35, confidence: 0.21)
        ]

        let segments = KaraokeLineTimingMapper.lineSegments(
            for: lyrics,
            recognition: recognition,
            audioDurationSeconds: 5.0
        )

        XCTAssertEqual(segments.count, 4)

        for index in 1..<segments.count {
            XCTAssertGreaterThanOrEqual(segments[index].startSeconds, segments[index - 1].endSeconds - 0.001)
        }

        let secondDuration = segments[1].endSeconds - segments[1].startSeconds
        let thirdDuration = segments[2].endSeconds - segments[2].startSeconds
        XCTAssertGreaterThan(secondDuration, 0.18)
        XCTAssertGreaterThan(thirdDuration, 0.18)

        let jumpAfterFirst = segments[1].startSeconds - segments[0].endSeconds
        XCTAssertLessThan(jumpAfterFirst, 1.0)
    }
}
