import XCTest
@testable import kyouku

/// Canonical contract tests for furigana-related ranges.
///
/// Every `rangeStart`/`rangeLength` pair in the app is measured in UTF-16 code
/// units so they round-trip cleanly through `NSRange` when bridging to
/// Foundation APIs. Furigana matchers, override stores, and future resolvers
/// must all conform to these expectations.
final class TextRangeTests: XCTestCase {
    /// Demonstrates that UTF-16 ranges continue to work even when the text
    /// includes surrogate-pair scalars such as emoji and regional indicators.
    func testUTF16RangesAlignWithNonBMPCharacters() {
        let text = "漢😀字🇯🇵仮名"
        let rangeStart = 1   // Skip the leading CJK character (1 UTF-16 unit)
        let rangeLength = 7  // 😀 (2) + 字 (1) + 🇯 (2) + 🇵 (2)
        let expected = "😀字🇯🇵"

        // This mirrors how we build NSRange-backed spans elsewhere in the app.
        let nsRange = NSRange(location: rangeStart, length: rangeLength)
        let nsSubstring = (text as NSString).substring(with: nsRange)
        XCTAssertEqual(nsSubstring, expected)

        // UTF-16 view extraction proves that the same offsets work without NSString.
        let utf16View = text.utf16
        let startIndex = utf16View.index(utf16View.startIndex, offsetBy: rangeStart)
        let endIndex = utf16View.index(startIndex, offsetBy: rangeLength)
        let slice = utf16View[startIndex..<endIndex]
        let utf16Substring = String(decoding: slice, as: UTF16.self)
        XCTAssertEqual(utf16Substring, expected)
    }
}
