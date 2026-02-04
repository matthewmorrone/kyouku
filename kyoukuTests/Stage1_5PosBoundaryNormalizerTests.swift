import XCTest
@testable import kyouku

final class Stage1_5PosBoundaryNormalizerTests: XCTestCase {
    private func mecab(_ range: NSRange, surface: String, pos: String) -> SpanReadingAttacher.MeCabAnnotation {
        SpanReadingAttacher.MeCabAnnotation(
            range: range,
            reading: surface,
            surface: surface,
            dictionaryForm: surface,
            partOfSpeech: pos
        )
    }

    func testSplitsSpanAtAdjacentTokenBoundary() {
        let text = "食べる"
        let nsText = text as NSString
        let spans = [
            TextSpan(range: NSRange(location: 0, length: 3), surface: text, isLexiconMatch: true)
        ]
        let mecab = [
            mecab(NSRange(location: 0, length: 2), surface: "食べ", pos: "動詞"),
            mecab(NSRange(location: 2, length: 1), surface: "る", pos: "助動詞")
        ]

        let result = Stage1_5PosBoundaryNormalizer.apply(text: nsText, spans: spans, mecab: mecab)

        let expected = [
            TextSpan(range: NSRange(location: 0, length: 2), surface: nsText.substring(with: NSRange(location: 0, length: 2)), isLexiconMatch: false),
            TextSpan(range: NSRange(location: 2, length: 1), surface: nsText.substring(with: NSRange(location: 2, length: 1)), isLexiconMatch: false)
        ]
        XCTAssertEqual(result.spans, expected)
        XCTAssertEqual(result.forcedCuts, [2])
    }

    func testKeepsSpanFullyContainedInToken() {
        let text = "食べる"
        let nsText = text as NSString
        let spans = [
            TextSpan(range: NSRange(location: 0, length: 2), surface: nsText.substring(with: NSRange(location: 0, length: 2)), isLexiconMatch: true)
        ]
        let mecab = [
            mecab(NSRange(location: 0, length: 2), surface: "食べ", pos: "動詞"),
            mecab(NSRange(location: 2, length: 1), surface: "る", pos: "助動詞")
        ]

        let result = Stage1_5PosBoundaryNormalizer.apply(text: nsText, spans: spans, mecab: mecab)

        XCTAssertEqual(result.spans, spans)
        XCTAssertTrue(result.forcedCuts.isEmpty)
    }
}
