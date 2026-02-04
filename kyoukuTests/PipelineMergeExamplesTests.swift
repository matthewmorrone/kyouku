import XCTest
@testable import kyouku

final class PipelineMergeExamplesTests: XCTestCase {
    private func semanticSurfaces(_ text: String) async throws -> [String] {
        let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(text: text, context: "test")
        return stage2.semanticSpans.map { $0.surface }
    }

    func testTeWaKureruNegativeSplitsCorrectly() async throws {
        // 気づいて + は + くれなくて (avoid incorrect はく + れ…)
        XCTAssertEqual(try await semanticSurfaces("気づいてはくれなくて"), ["気づいて", "は", "くれなくて"])
    }

    func testHitoribocchiFinalParticle() async throws {
        XCTAssertEqual(try await semanticSurfaces("ひとりぼっちよ"), ["ひとりぼっち", "よ"])
    }

    func testDesireTaiKeepsFinalYoSeparate() async throws {
        XCTAssertEqual(try await semanticSurfaces("会いたいよ"), ["会いたい", "よ"])
    }

    func testTaiConjunctiveTakuMerges() async throws {
        XCTAssertEqual(try await semanticSurfaces("泣きたく"), ["泣きたく"])
    }

    func testPastTaMerges() async throws {
        XCTAssertEqual(try await semanticSurfaces("出会った"), ["出会った"])
    }

    func testPassivePotentialRareruMerges() async throws {
        XCTAssertEqual(try await semanticSurfaces("見つけられる"), ["見つけられる"])
    }
}
