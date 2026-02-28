import XCTest
@testable import kyouku

final class KaraokeAlignmentModelsTests: XCTestCase {
    func testDecodingLegacyAlignmentDefaultsVersionAndGranularity() throws {
        let json = """
        {
          "generatedAt": "2026-02-01T12:00:00Z",
          "localeIdentifier": "ja-JP",
          "audioDurationSeconds": 12.5,
          "strategy": "fallback_interpolation",
          "segments": [
            {
              "textRange": {"location": 0, "length": 5},
              "startSeconds": 0.0,
              "endSeconds": 2.0,
              "confidence": 0.05
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let alignment = try decoder.decode(KaraokeAlignment.self, from: Data(json.utf8))

        XCTAssertEqual(alignment.version, 1)
        XCTAssertEqual(alignment.granularities, [.line])
        XCTAssertEqual(alignment.segments.count, 1)
        XCTAssertNil(alignment.segments[0].tokenSegments)
        XCTAssertNil(alignment.segments[0].phraseSegments)
    }

    func testEncodingAndDecodingAlignmentPreservesGranularitiesAndChildren() throws {
        let token = KaraokeAlignmentChildSegment(
            granularity: .token,
            textRange: NSRange(location: 0, length: 1),
            startSeconds: 0.1,
            endSeconds: 0.4,
            confidence: 0.8
        )
        let phrase = KaraokeAlignmentChildSegment(
            granularity: .phrase,
            textRange: NSRange(location: 0, length: 3),
            startSeconds: 0.1,
            endSeconds: 1.1,
            confidence: 0.75
        )
        let segment = KaraokeAlignmentSegment(
            textRange: NSRange(location: 0, length: 5),
            startSeconds: 0.1,
            endSeconds: 1.3,
            confidence: 0.81,
            phraseSegments: [phrase],
            tokenSegments: [token]
        )

        let alignment = KaraokeAlignment(
            generatedAt: Date(timeIntervalSince1970: 1_705_000_000),
            localeIdentifier: "ja-JP",
            audioDurationSeconds: 12.0,
            strategy: .speechOnDevice,
            version: KaraokeAlignment.currentVersion,
            granularities: [.line, .phrase, .token],
            segments: [segment],
            diagnostics: ["Recognition success segments=12"]
        )

        let encoded = try JSONEncoder().encode(alignment)
        let decoded = try JSONDecoder().decode(KaraokeAlignment.self, from: encoded)

        XCTAssertEqual(decoded.version, KaraokeAlignment.currentVersion)
        XCTAssertEqual(decoded.granularities, [.line, .phrase, .token])
        XCTAssertEqual(decoded.segments.count, 1)
        XCTAssertEqual(decoded.segments[0].tokenSegments?.count, 1)
        XCTAssertEqual(decoded.segments[0].phraseSegments?.count, 1)
        XCTAssertEqual(decoded.segments[0].tokenSegments?.first?.granularity, .token)
        XCTAssertEqual(decoded.segments[0].phraseSegments?.first?.granularity, .phrase)
        XCTAssertEqual(decoded.diagnostics?.first, "Recognition success segments=12")
    }
}
