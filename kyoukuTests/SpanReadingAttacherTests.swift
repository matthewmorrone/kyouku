import XCTest
import CoreFoundation
@testable import kyouku

final class SpanReadingAttacherTests: XCTestCase {
    func testKanjiFallbackWithOkurigana() {
        assertFallback(surface: "会う", readingKatakana: "アウ", expectedHiragana: "あ")
        assertFallback(surface: "会いたい", readingKatakana: "アイタイ", expectedHiragana: "あ")
        assertFallback(surface: "導かれ", readingKatakana: "ミチビカレ", expectedHiragana: "みちび")
    }

    func testKanjiFallbackWithoutOkuriganaKeepsFullReading() {
        assertFallback(surface: "過去", readingKatakana: "カコ", expectedHiragana: "かこ")
    }

    func testKanjiFallbackForSubsetOfToken() {
        // Token surface includes trailing okurigana but span may only cover the kanji portion.
        assertFallback(surface: "出会う", readingKatakana: "デアウ", expectedHiragana: "であ")
    }

    func testContextualRewrite_NaniToNan_ForNaniSurface何() {
        let text = "何でもない" as NSString
        let range = NSRange(location: 0, length: ("何" as NSString).length)
        let rewritten = SpanReadingAttacher.applyContextualReadingRules(surface: "何", reading: "なに", nsText: text, range: range)
        XCTAssertEqual(rewritten, "なん")
    }

    func testContextualRewrite_DoesNotRewriteOutsideTargetContext() {
        let text = "何が好き" as NSString
        let range = NSRange(location: 0, length: ("何" as NSString).length)
        let rewritten = SpanReadingAttacher.applyContextualReadingRules(surface: "何", reading: "なに", nsText: text, range: range)
        XCTAssertEqual(rewritten, "なに")
    }

    func testContextualRewrite_HitoriPrefixPreservesSuffixForIchininReading() {
        let text = "一人で来た" as NSString
        let surface = "一人で"
        let range = NSRange(location: 0, length: (surface as NSString).length)
        let rewritten = SpanReadingAttacher.applyContextualReadingRules(surface: surface, reading: "いちにんで", nsText: text, range: range)
        XCTAssertEqual(rewritten, "ひとりで")
    }

    func testContextualRewrite_NaniPrefixForMergedSurface() {
        let text = "何でもない" as NSString
        let surface = "何でもない"
        let range = NSRange(location: 0, length: (surface as NSString).length)
        let rewritten = SpanReadingAttacher.applyContextualReadingRules(surface: surface, reading: "なにでもない", nsText: text, range: range)
        XCTAssertEqual(rewritten, "なんでもない")
    }

    private func assertFallback(surface: String, readingKatakana: String, expectedHiragana: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let katakana = SpanReadingAttacher.kanjiReadingFromToken(tokenSurface: surface, tokenReadingKatakana: readingKatakana) else {
            return XCTFail("Expected fallback reading for \(surface)", file: file, line: line)
        }
        XCTAssertEqual(katakanaToHiragana(katakana), expectedHiragana, file: file, line: line)
    }

    private func katakanaToHiragana(_ text: String) -> String {
        let mutable = NSMutableString(string: text) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return mutable as String
    }
}
