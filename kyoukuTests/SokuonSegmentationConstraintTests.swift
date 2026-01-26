import XCTest
@testable import kyouku

final class SokuonSegmentationConstraintTests: XCTestCase {
    func testDoesNotEndSegmentOnSokuonInsideWord() async throws {
        let text = "涙が星になっても"
        let spans = try await SegmentationService.shared.segment(text: text)
        XCTAssertFalse(spans.contains(where: { $0.surface.hasSuffix("っ") || $0.surface.hasSuffix("ッ") }))
    }

    func testAllowsTerminalSokuonAtEndOfLine() async throws {
        let text = "あっ"
        let spans = try await SegmentationService.shared.segment(text: text)
        // End-of-text is considered end-of-line/truncation, so a terminal sokuon token is allowed.
        XCTAssertTrue(spans.contains(where: { $0.surface == "あっ" }))
    }

    func testBindsSokuonAcrossScriptBoundary() async throws {
        let text = "まっ赤"
        let spans = try await SegmentationService.shared.segment(text: text)
        // Ensure we never produce a segment that ends with っ before 赤.
        XCTAssertFalse(spans.contains(where: { $0.surface == "まっ" }))
        XCTAssertTrue(spans.contains(where: { $0.surface.contains("まっ赤") }))
    }

    func testDoesNotStartSegmentWithSokuonInsideWord() async throws {
        let text = "もっともっと愛している"
        let ns = text as NSString
        let spans = try await SegmentationService.shared.segment(text: text)

        func isBoundary(_ ch: unichar) -> Bool {
            guard let scalar = UnicodeScalar(ch) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.punctuationCharacters.contains(scalar) ||
                CharacterSet.symbols.contains(scalar)
        }

        for span in spans {
            guard span.surface.hasPrefix("っ") || span.surface.hasPrefix("ッ") else { continue }
            if span.range.location == 0 {
                continue
            }
            let prev = ns.character(at: span.range.location - 1)
            XCTAssertTrue(isBoundary(prev), "Unexpected leading sokuon token inside word: \(span.surface)")
        }

        // Common failure mode: "もっと" split into "も" + "っと".
        XCTAssertFalse(spans.contains(where: { $0.surface == "っと" }))
    }
}
