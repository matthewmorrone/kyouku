import XCTest
@testable import kyouku

@MainActor
final class PipelineMergeExamplesTests: XCTestCase {
    private func semanticSurfaces(_ text: String) async throws -> [String] {
        let stage2 = try await FuriganaAttributedTextBuilder.computeStage2(text: text, context: "test")
        return stage2.semanticSpans.map { $0.surface }
    }

    func testTeWaKureruNegativeSplitsCorrectly() async throws {
        // 気づいて + は + くれなくて (avoid incorrect はく + れ…)
        let surfaces = try await semanticSurfaces("気づいてはくれなくて")
        XCTAssertEqual(surfaces, ["気づいて", "は", "くれなくて"])
    }

    func testHitoribocchiFinalParticle() async throws {
        let surfaces = try await semanticSurfaces("ひとりぼっちよ")
        XCTAssertEqual(surfaces, ["ひとりぼっち", "よ"])
    }

    func testDesireTaiKeepsFinalYoSeparate() async throws {
        let surfaces = try await semanticSurfaces("会いたいよ")
        XCTAssertEqual(surfaces, ["会いたい", "よ"])
    }

    func testTaiConjunctiveTakuMerges() async throws {
        let surfaces = try await semanticSurfaces("泣きたく")
        XCTAssertEqual(surfaces, ["泣きたく"])
    }

    func testPastTaMerges() async throws {
        let surfaces = try await semanticSurfaces("出会った")
        XCTAssertEqual(surfaces, ["出会った"])
    }

    func testPassivePotentialRareruMerges() async throws {
        let surfaces = try await semanticSurfaces("見つけられる")
        XCTAssertEqual(surfaces, ["見つけられる"])
    }
}
