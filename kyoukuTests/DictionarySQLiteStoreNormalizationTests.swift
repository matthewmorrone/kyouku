import XCTest
@testable import kyouku

final class DictionarySQLiteStoreNormalizationTests: XCTestCase {
    func testRomanToHiraganaHandlesMacronsAndDigraphs() async {
        let store = DictionarySQLiteStore.shared

        let result = await store.romanToHiragana("Tōkyō")

        XCTAssertEqual(result, "とうきょう")
    }

    func testRomanToHiraganaHandlesSokuonAndN() async {
        let store = DictionarySQLiteStore.shared

        let gakkou = await store.romanToHiragana("gakkou")
        let kanpai = await store.romanToHiragana("kanpai")
        let shinyu = await store.romanToHiragana("shin'yu")

        XCTAssertEqual(gakkou, "がっこう")
        XCTAssertEqual(kanpai, "かんぱい")
        XCTAssertEqual(shinyu, "しんゆ")
    }

    func testLatinToKanaCandidatesIncludesHiraganaAndKatakana() async {
        let store = DictionarySQLiteStore.shared

        let candidates = await store.latinToKanaCandidates(for: "gakkou")

        XCTAssertEqual(Set(candidates), Set(["がっこう", "ガッコウ"]))
    }

    func testNormalizedKanaVariantsHandlesPotentialAndGodanForms() async {
        let store = DictionarySQLiteStore.shared

        let ichidan = await store.normalizedKanaVariants(for: "たべられる")
        let godan = await store.normalizedKanaVariants(for: "よめる")

        XCTAssertTrue(ichidan.contains("たべる"))
        XCTAssertTrue(ichidan.contains("タベル"))
        XCTAssertTrue(godan.contains("よむ"))
        XCTAssertTrue(godan.contains("ヨム"))
    }

    func testNormalizedKanaVariantsHandlesAdjectivesAndSuruNouns() async {
        let store = DictionarySQLiteStore.shared

        let adjective = await store.normalizedKanaVariants(for: "たかかったです")
        let suru = await store.normalizedKanaVariants(for: "べんきょうしている")

        XCTAssertTrue(adjective.contains("たかい"))
        XCTAssertTrue(adjective.contains("タカイ"))
        XCTAssertTrue(suru.contains("べんきょうする"))
        XCTAssertTrue(suru.contains("べんきょう"))
    }

    func testSanitizeSurfaceTokenStripsInvalidCharacters() async {
        let store = DictionarySQLiteStore.shared

        let sanitized = await store.sanitizeSurfaceToken(" A-1 ー々漢字!?abc ")

        XCTAssertEqual(sanitized, "A1ー々漢字abc")
    }
}
