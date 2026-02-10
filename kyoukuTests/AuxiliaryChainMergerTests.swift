import XCTest
@testable import kyouku

final class AuxiliaryChainMergerTests: XCTestCase {
    private func mecab(_ range: NSRange, surface: String, pos: String) -> SpanReadingAttacher.MeCabAnnotation {
        SpanReadingAttacher.MeCabAnnotation(
            range: range,
            reading: surface,
            surface: surface,
            dictionaryForm: surface,
            partOfSpeech: pos
        )
    }

    func testMergesAuxiliaryChainByPosMetadata() {
        let text = "光ってる"
        let nsText = text as NSString
        let spans = [
            TextSpan(range: NSRange(location: 0, length: 2), surface: nsText.substring(with: NSRange(location: 0, length: 2)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 2, length: 1), surface: nsText.substring(with: NSRange(location: 2, length: 1)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 3, length: 1), surface: nsText.substring(with: NSRange(location: 3, length: 1)), isLexiconMatch: false)
        ]
        let mecab = [
            mecab(NSRange(location: 0, length: 2), surface: "光っ", pos: "動詞"),
            mecab(NSRange(location: 2, length: 1), surface: "て", pos: "助詞,接続助詞"),
            mecab(NSRange(location: 3, length: 1), surface: "る", pos: "動詞,非自立")
        ]

        let result = AuxiliaryChainMerger.apply(text: nsText, spans: spans, hardCuts: [], mecab: mecab)

        XCTAssertEqual(result.merges, 1)
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans.first?.surface, text)
    }

    func testAuthoritativeCoverageMergesUnlessHardCutBlocks() {
        let text = "食べ"
        let nsText = text as NSString
        let spans = [
            TextSpan(range: NSRange(location: 0, length: 1), surface: nsText.substring(with: NSRange(location: 0, length: 1)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 1, length: 1), surface: nsText.substring(with: NSRange(location: 1, length: 1)), isLexiconMatch: false)
        ]
        let mecab = [
            mecab(NSRange(location: 0, length: 2), surface: "食べ", pos: "動詞")
        ]

        let merged = AuxiliaryChainMerger.apply(text: nsText, spans: spans, hardCuts: [], mecab: mecab)
        XCTAssertEqual(merged.spans.count, 1)
        XCTAssertEqual(merged.spans.first?.surface, text)

        let blocked = AuxiliaryChainMerger.apply(text: nsText, spans: spans, hardCuts: [1], mecab: mecab)
        XCTAssertEqual(blocked.spans.count, spans.count)
        XCTAssertEqual(blocked.merges, 0)
    }

    func testAuthoritativeCoverageIgnoresNonSelectedParticleCandidateAtBoundary() {
        let text = "くれなくて"
        let nsText = text as NSString
        let spans = [
            TextSpan(range: NSRange(location: 0, length: 2), surface: nsText.substring(with: NSRange(location: 0, length: 2)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 2, length: 3), surface: nsText.substring(with: NSRange(location: 2, length: 3)), isLexiconMatch: false)
        ]
        let mecab = [
            mecab(NSRange(location: 0, length: 5), surface: "くれなくて", pos: "動詞"),
            // Overlapping candidate at the boundary that should not block authoritative coverage merge.
            mecab(NSRange(location: 2, length: 1), surface: "な", pos: "助詞,係助詞"),
            mecab(NSRange(location: 2, length: 2), surface: "なく", pos: "助動詞"),
            mecab(NSRange(location: 4, length: 1), surface: "て", pos: "助詞,接続助詞")
        ]

        let result = AuxiliaryChainMerger.apply(text: nsText, spans: spans, hardCuts: [], mecab: mecab)

        XCTAssertEqual(result.merges, 1)
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans.first?.surface, text)
    }

    func testMergesCoarsePosNegativeAuxChain() {
        let text = "くれなくて"
        let nsText = text as NSString
        let spans = [
            TextSpan(range: NSRange(location: 0, length: 2), surface: nsText.substring(with: NSRange(location: 0, length: 2)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 2, length: 2), surface: nsText.substring(with: NSRange(location: 2, length: 2)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 4, length: 1), surface: nsText.substring(with: NSRange(location: 4, length: 1)), isLexiconMatch: false)
        ]
        let mecab = [
            SpanReadingAttacher.MeCabAnnotation(
                range: NSRange(location: 0, length: 2),
                reading: "くれ",
                surface: "くれ",
                dictionaryForm: "くれる",
                partOfSpeech: "verb"
            ),
            SpanReadingAttacher.MeCabAnnotation(
                range: NSRange(location: 2, length: 2),
                reading: "なく",
                surface: "なく",
                dictionaryForm: "ない",
                partOfSpeech: "unknown"
            ),
            SpanReadingAttacher.MeCabAnnotation(
                range: NSRange(location: 4, length: 1),
                reading: "て",
                surface: "て",
                dictionaryForm: "て",
                partOfSpeech: "particle"
            )
        ]

        let result = AuxiliaryChainMerger.apply(text: nsText, spans: spans, hardCuts: [], mecab: mecab)

        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(result.spans.first?.surface, text)
    }

    func testKeepsBoundarySensitiveParticleSeparateWithCoarsePos() {
        let text = "気づいては"
        let nsText = text as NSString
        let spans = [
            TextSpan(range: NSRange(location: 0, length: 3), surface: nsText.substring(with: NSRange(location: 0, length: 3)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 3, length: 1), surface: nsText.substring(with: NSRange(location: 3, length: 1)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 4, length: 1), surface: nsText.substring(with: NSRange(location: 4, length: 1)), isLexiconMatch: false)
        ]
        let mecab = [
            SpanReadingAttacher.MeCabAnnotation(
                range: NSRange(location: 0, length: 3),
                reading: "きづい",
                surface: "気づい",
                dictionaryForm: "気づく",
                partOfSpeech: "verb"
            ),
            SpanReadingAttacher.MeCabAnnotation(
                range: NSRange(location: 3, length: 1),
                reading: "て",
                surface: "て",
                dictionaryForm: "て",
                partOfSpeech: "particle"
            ),
            SpanReadingAttacher.MeCabAnnotation(
                range: NSRange(location: 4, length: 1),
                reading: "は",
                surface: "は",
                dictionaryForm: "は",
                partOfSpeech: "particle"
            )
        ]

        let result = AuxiliaryChainMerger.apply(text: nsText, spans: spans, hardCuts: [], mecab: mecab)

        XCTAssertEqual(result.spans.map(\.surface), ["気づいて", "は"])
    }
}
