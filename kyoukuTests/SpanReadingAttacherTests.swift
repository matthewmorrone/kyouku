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
