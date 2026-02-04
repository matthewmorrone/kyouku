import XCTest
@testable import kyouku

final class JapaneseVerbConjugatorTests: XCTestCase {
    private func surfaceMap(_ items: [JapaneseVerbConjugation]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0.surface) })
    }

    func testIchidanCommonConjugations() {
        let items = JapaneseVerbConjugator.conjugations(for: "食べる", verbClass: .ichidan, set: .all)
        let m = surfaceMap(items)
        XCTAssertEqual(m["Polite (ます)"], "食べます")
        XCTAssertEqual(m["て-form"], "食べて")
        XCTAssertEqual(m["Past (た)"], "食べた")
        XCTAssertEqual(m["Negative (ない)"], "食べない")
        XCTAssertEqual(m["Volitional"], "食べよう")
        XCTAssertEqual(m["Potential"], "食べられる")
        XCTAssertEqual(m["Imperative"], "食べろ")
    }

    func testGodanCommonConjugations() {
        let items = JapaneseVerbConjugator.conjugations(for: "書く", verbClass: .godan, set: .all)
        let m = surfaceMap(items)
        XCTAssertEqual(m["Polite (ます)"], "書きます")
        XCTAssertEqual(m["て-form"], "書いて")
        XCTAssertEqual(m["Past (た)"], "書いた")
        XCTAssertEqual(m["Negative (ない)"], "書かない")
        XCTAssertEqual(m["Volitional"], "書こう")
        XCTAssertEqual(m["Potential"], "書ける")
        XCTAssertEqual(m["Imperative"], "書け")
        XCTAssertEqual(m["Conditional (ば)"], "書けば")
    }

    func testGodanIkuException() {
        let items = JapaneseVerbConjugator.conjugations(for: "行く", verbClass: .godan, set: .all)
        let m = surfaceMap(items)
        XCTAssertEqual(m["て-form"], "行って")
        XCTAssertEqual(m["Past (た)"], "行った")
    }

    func testSuruCompound() {
        let items = JapaneseVerbConjugator.conjugations(for: "勉強する", verbClass: .suru, set: .all)
        let m = surfaceMap(items)
        XCTAssertEqual(m["Polite (ます)"], "勉強します")
        XCTAssertEqual(m["て-form"], "勉強して")
        XCTAssertEqual(m["Negative (ない)"], "勉強しない")
        XCTAssertEqual(m["Potential"], "勉強できる")
    }

    func testKuruKanaAndKanji() {
        do {
            let items = JapaneseVerbConjugator.conjugations(for: "くる", verbClass: .kuru, set: .all)
            let m = surfaceMap(items)
            XCTAssertEqual(m["Polite (ます)"], "きます")
            XCTAssertEqual(m["て-form"], "きて")
            XCTAssertEqual(m["Negative (ない)"], "こない")
            XCTAssertEqual(m["Imperative"], "こい")
        }
        do {
            let items = JapaneseVerbConjugator.conjugations(for: "来る", verbClass: .kuru, set: .all)
            let m = surfaceMap(items)
            XCTAssertEqual(m["Polite (ます)"], "来ます")
            XCTAssertEqual(m["て-form"], "来て")
            XCTAssertEqual(m["Negative (ない)"], "来ない")
            XCTAssertEqual(m["Imperative"], "来い")
        }
    }
}
