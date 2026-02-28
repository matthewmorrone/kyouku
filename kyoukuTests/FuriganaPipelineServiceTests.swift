import XCTest
@testable import kyouku

@MainActor
final class FuriganaPipelineServiceTests: XCTestCase {
    private struct RubyRun: Equatable {
        let base: String
        let reading: String
    }

    private func makeInput(
        text: String,
        showFurigana: Bool,
        recomputeSpans: Bool,
        existingSpans: [AnnotatedSpan]? = nil,
        existingSemanticSpans: [SemanticSpan] = [],
        knownWordSurfaceKeys: Set<String> = []
    ) -> FuriganaPipelineService.Input {
        FuriganaPipelineService.Input(
            text: text,
            showFurigana: showFurigana,
            needsTokenHighlights: false,
            textSize: 17,
            furiganaSize: 9,
            recomputeSpans: recomputeSpans,
            existingSpans: existingSpans,
            existingSemanticSpans: existingSemanticSpans,
            amendedSpans: nil,
            hardCuts: [],
            readingOverrides: [],
            context: "FuriganaPipelineServiceTests",
            padHeadwordSpacing: false,
            headwordSpacingAmount: 1.0,
            knownWordSurfaceKeys: knownWordSurfaceKeys
        )
    }

    private func rubyRuns(from attributed: NSAttributedString) -> [RubyRun] {
        let key = NSAttributedString.Key("RubyReadingText")
        let ns = attributed.string as NSString
        var runs: [RubyRun] = []
        attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length), options: []) { value, range, _ in
            guard let reading = value as? String else { return }
            guard range.length > 0 else { return }
            let base = ns.substring(with: range)
            runs.append(RubyRun(base: base, reading: reading))
        }
        return runs
    }

    private func assertPipeline(
        text: String,
        expectedSegments: [String],
        expectedRubyRuns: [RubyRun],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let service = FuriganaPipelineService()
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )
        let result = await service.render(input)

        let actualSegments = result.semanticSpans.map(\.surface)
        XCTAssertEqual(
            actualSegments,
            expectedSegments,
            "actualSegments=\(actualSegments)\nexpectedSegments=\(expectedSegments)",
            file: file,
            line: line
        )
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string", file: file, line: line)
        }
        XCTAssertEqual(attributed.string, text, file: file, line: line)
        let actualRubyRuns = rubyRuns(from: attributed)
        XCTAssertEqual(
            actualRubyRuns,
            expectedRubyRuns,
            "actualRubyRuns=\(actualRubyRuns)\nexpectedRubyRuns=\(expectedRubyRuns)",
            file: file,
            line: line
        )
    }

    func testSkipsWhenNoConsumersNeedSpans() async {
        let service = FuriganaPipelineService()
        let placeholderSpan = AnnotatedSpan(
            span: TextSpan(range: NSRange(location: 0, length: 1), surface: "星"),
            readingKana: "ほし"
        )
        let placeholderSemantic = SemanticSpan(
            range: placeholderSpan.span.range,
            surface: placeholderSpan.span.surface,
            sourceSpanIndices: 0..<1,
            readingKana: placeholderSpan.readingKana
        )
        let input = makeInput(
            text: "星",
            showFurigana: false,
            recomputeSpans: false,
            existingSpans: [placeholderSpan],
            existingSemanticSpans: [placeholderSemantic]
        )

        let result = await service.render(input)
        XCTAssertEqual(result.spans, [placeholderSpan])
        XCTAssertNil(result.attributedString)
    }

    func testProducesAnnotatedTextWhenEnabled() async {
        let service = FuriganaPipelineService()
        let text = "星を見る"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        XCTAssertNotNil(result.spans)
        XCTAssertEqual(result.attributedString?.string, text)
        XCTAssertEqual(result.attributedString?.length, text.utf16.count)
    }

    func testPasteStyleOkuriganaDoesNotOverTrimInsideReading() async {
        // Regression: In the paste area, "私たち" was projecting "わ" over 私.
        // The expected kanji reading chunk is "わたし".
        let service = FuriganaPipelineService()
        let text = "私たち"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        var effectiveRange = NSRange(location: 0, length: 0)
        let reading = attributed.attribute(key, at: 0, effectiveRange: &effectiveRange) as? String
        XCTAssertEqual(reading, "わたし")
    }

    func testCounterReadingInPhrase_UsesHitoriForHitoriDe() async {
        let service = FuriganaPipelineService()
        let text = "一人で来た"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        let ns = text as NSString
        let hitoriIndex = ns.range(of: "一人").location
        XCTAssertNotEqual(hitoriIndex, NSNotFound)
        let reading = attributed.attribute(key, at: hitoriIndex, effectiveRange: nil) as? String
        XCTAssertEqual(reading, "ひとり")
    }

    func testCounterParticleBoundary_RemainsSplitInSemanticSpans() async {
        let service = FuriganaPipelineService()
        let text = "一人で来た"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        let semantic = result.semanticSpans.map(\.surface)
        let stage2 = result.spans?.map { $0.span.surface } ?? []
        XCTAssertEqual(
            semantic,
            ["一人", "で", "来た"],
            "semantic=\(semantic)\nstage2=\(stage2)"
        )
    }

    func testParticleChainNiWaRemainsSplitInSemanticSpans() async {
        let service = FuriganaPipelineService()
        let text = "帰りには"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        let semantic = result.semanticSpans.map(\.surface)
        let stage2 = result.spans?.map { $0.span.surface } ?? []
        XCTAssertEqual(
            semantic,
            ["帰り", "に", "は"],
            "semantic=\(semantic)\nstage2=\(stage2)"
        )
    }

    func testClassicalNegativeZuMergesIntoSingleSemanticSpan() async {
        let service = FuriganaPipelineService()
        let text = "侮らず"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        let semantic = result.semanticSpans.map(\.surface)
        XCTAssertEqual(semantic, ["侮らず"])
    }

    func testNanReadingAppliedForMergedNaniPrefixSurface() async {
        let service = FuriganaPipelineService()
        let text = "何でもない"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        let reading = attributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(reading, "なん")
    }

    func testKnownWordRubySuppressionRemovesRuby() async {
        let service = FuriganaPipelineService()
        let text = "星を見る"
        let input = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: true,
            knownWordSurfaceKeys: ["星"]
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        let key = NSAttributedString.Key("RubyReadingText")
        let reading = attributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertNil(reading)
    }

    func testKnownWordRubySuppressionUsesLemmaCandidates() async {
        let service = FuriganaPipelineService()
        let text = "星"
        let spanRange = NSRange(location: 0, length: 1)
        let stage2Span = AnnotatedSpan(
            span: TextSpan(range: spanRange, surface: text),
            readingKana: "ほし",
            lemmaCandidates: ["ほし"]
        )
        let semanticSpan = SemanticSpan(
            range: spanRange,
            surface: text,
            sourceSpanIndices: 0..<1,
            readingKana: "ほし"
        )

        let baselineInput = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: false,
            existingSpans: [stage2Span],
            existingSemanticSpans: [semanticSpan]
        )
        let baselineResult = await service.render(baselineInput)
        guard let baselineAttributed = baselineResult.attributedString else {
            return XCTFail("Expected attributed string")
        }
        let key = NSAttributedString.Key("RubyReadingText")
        let baselineReading = baselineAttributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(baselineReading, "ほし")

        let suppressionInput = makeInput(
            text: text,
            showFurigana: true,
            recomputeSpans: false,
            existingSpans: [stage2Span],
            existingSemanticSpans: [semanticSpan],
            knownWordSurfaceKeys: ["ほし"]
        )
        let suppressedResult = await service.render(suppressionInput)
        guard let suppressedAttributed = suppressedResult.attributedString else {
            return XCTFail("Expected attributed string")
        }
        let suppressedReading = suppressedAttributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertNil(suppressedReading)
    }

    func testRubyDoesNotPropagateToTrailingPunctuationWhenPaddingEnabled() async {
        let service = FuriganaPipelineService()
        let text = "星。"
        let input = FuriganaPipelineService.Input(
            text: text,
            showFurigana: true,
            needsTokenHighlights: false,
            textSize: 17,
            furiganaSize: 9,
            recomputeSpans: true,
            existingSpans: nil,
            existingSemanticSpans: [],
            amendedSpans: nil,
            hardCuts: [],
            readingOverrides: [],
            context: "FuriganaPipelineServiceTests",
            padHeadwordSpacing: true,
            headwordSpacingAmount: 1.0,
            knownWordSurfaceKeys: []
        )

        let result = await service.render(input)
        guard let attributed = result.attributedString else {
            return XCTFail("Expected attributed string")
        }

        XCTAssertEqual(attributed.string, text)
        XCTAssertEqual(attributed.length, text.utf16.count)

        let key = NSAttributedString.Key("RubyReadingText")
        let ns = attributed.string as NSString
        let punctIndex = ns.range(of: "。").location
        XCTAssertNotEqual(punctIndex, NSNotFound)

        // The headword should have ruby…
        let headwordReading = attributed.attribute(key, at: 0, effectiveRange: nil) as? String
        XCTAssertNotNil(headwordReading)

        // …but the trailing punctuation must not.
        let punctReading = attributed.attribute(key, at: punctIndex, effectiveRange: nil) as? String
        XCTAssertNil(punctReading)
    }

    func testPasteExemplar_SegmentationAndRuby_PassageOne() async {
        let text = "「何でもない」と彼は言った。私たちは時々まっ赤な空を見て、気づいてはくれなくて、ただ黙って歩いた。一人で来たはずの彼が、帰りには二人になっていて、切なトキメキだけが胸に残った。"

        let expectedSegments = [
            "「", "何でもない", "」", "と", "彼", "は", "言った", "。",
            "私たち", "は", "時々", "まっ赤", "な", "空", "を", "見て", "、",
            "気づいて", "は", "くれなくて", "、", "ただ", "黙って", "歩いた", "。",
            "一人", "で", "来た", "はず", "の", "彼", "が", "、",
            "帰り", "に", "は", "二人", "に", "なっていて", "、",
            "切", "な", "トキメキ", "だけ", "が", "胸", "に", "残った", "。"
        ]

        let expectedRubyRuns = [
            RubyRun(base: "何", reading: "なん"),
            RubyRun(base: "彼", reading: "かれ"),
            RubyRun(base: "言", reading: "い"),
            RubyRun(base: "私", reading: "わたし"),
            RubyRun(base: "時々", reading: "ときどき"),
            RubyRun(base: "赤", reading: "あか"),
            RubyRun(base: "空", reading: "そら"),
            RubyRun(base: "見", reading: "み"),
            RubyRun(base: "気", reading: "き"),
            RubyRun(base: "黙", reading: "だま"),
            RubyRun(base: "歩", reading: "ある"),
            RubyRun(base: "一人", reading: "ひとり"),
            RubyRun(base: "来", reading: "き"),
            RubyRun(base: "彼", reading: "かれ"),
            RubyRun(base: "帰", reading: "かえ"),
            RubyRun(base: "二人", reading: "ふたり"),
            RubyRun(base: "切", reading: "せつ"),
            RubyRun(base: "胸", reading: "むね"),
            RubyRun(base: "残", reading: "のこ")
        ]

        await assertPipeline(
            text: text,
            expectedSegments: expectedSegments,
            expectedRubyRuns: expectedRubyRuns
        )
    }

    func testPasteExemplar_SegmentationAndRuby_PassageTwo() async {
        let text = "予め志を胸に秘め、漸く趣を語り、遮る声にも侮らず、滞る息で凍える夜道を歩いた。承るたびに畏まり、和らぐ気配だけを頼りに進んだ。"

        let expectedSegments = [
            "予め", "志", "を", "胸", "に", "秘め", "、",
            "漸く", "趣", "を", "語り", "、",
            "遮る", "声", "に", "も", "侮らず", "、",
            "滞る", "息", "で", "凍える", "夜道", "を", "歩いた", "。",
            "承る", "たびに", "畏まり", "、",
            "和らぐ", "気配", "だけ", "を", "頼り", "に", "進んだ", "。"
        ]

        let expectedRubyRuns = [
            RubyRun(base: "予", reading: "あらかじ"),
            RubyRun(base: "志", reading: "こころざし"),
            RubyRun(base: "胸", reading: "むね"),
            RubyRun(base: "秘", reading: "ひ"),
            RubyRun(base: "漸", reading: "ようや"),
            RubyRun(base: "趣", reading: "おもむき"),
            RubyRun(base: "語", reading: "かた"),
            RubyRun(base: "遮", reading: "さえぎ"),
            RubyRun(base: "声", reading: "こえ"),
            RubyRun(base: "侮", reading: "あなど"),
            RubyRun(base: "滞", reading: "とどこお"),
            RubyRun(base: "息", reading: "いき"),
            RubyRun(base: "凍", reading: "こご"),
            RubyRun(base: "夜道", reading: "よみち"),
            RubyRun(base: "歩", reading: "ある"),
            RubyRun(base: "承", reading: "うけたまわ"),
            RubyRun(base: "畏", reading: "かしこ"),
            RubyRun(base: "和", reading: "やわ"),
            RubyRun(base: "気配", reading: "けはい"),
            RubyRun(base: "頼", reading: "たよ"),
            RubyRun(base: "進", reading: "すす")
        ]

        await assertPipeline(
            text: text,
            expectedSegments: expectedSegments,
            expectedRubyRuns: expectedRubyRuns
        )
    }
}
