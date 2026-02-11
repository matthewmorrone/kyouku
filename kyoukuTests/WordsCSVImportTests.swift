import XCTest
@testable import kyouku

final class WordsCSVImportTests: XCTestCase {
    func testParseItemsListModeClassifiesKanjiKanaEnglish() {
        let text = """
        猫
        ねこ
        cat
        """

        let items = WordsCSVImport.parseItems(from: text)
        XCTAssertEqual(items.count, 3)

        XCTAssertEqual(items[0].finalSurface, "猫")
        XCTAssertNil(items[0].finalKana)
        XCTAssertNil(items[0].finalMeaning)

        XCTAssertNil(items[1].finalSurface)
        XCTAssertEqual(items[1].finalKana, "ねこ")
        XCTAssertNil(items[1].finalMeaning)

        XCTAssertNil(items[2].finalSurface)
        XCTAssertNil(items[2].finalKana)
        XCTAssertEqual(items[2].finalMeaning, "cat")
    }

    func testParseItemsDelimitedWithHeader() {
        let text = """
        word,reading,meaning,note
        猫,ねこ,cat,pet
        犬,いぬ,dog,
        """

        let items = WordsCSVImport.parseItems(from: text)
        XCTAssertEqual(items.count, 2)

        XCTAssertEqual(items[0].finalSurface, "猫")
        XCTAssertEqual(items[0].finalKana, "ねこ")
        XCTAssertEqual(items[0].finalMeaning, "cat")
        XCTAssertEqual(items[0].finalNote, "pet")

        XCTAssertEqual(items[1].finalSurface, "犬")
        XCTAssertEqual(items[1].finalKana, "いぬ")
        XCTAssertEqual(items[1].finalMeaning, "dog")
        XCTAssertNil(items[1].finalNote)
    }

    func testParseItemsDelimitedWithQuotedValues() {
        let text = """
        surface,meaning
        "猫,犬",cat
        """

        let items = WordsCSVImport.parseItems(from: text)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].finalSurface, "猫,犬")
        XCTAssertEqual(items[0].finalMeaning, "cat")
    }

    func testParseItemsHeaderlessClassification() {
        let text = """
        猫,ねこ,cat,common
        """

        let items = WordsCSVImport.parseItems(from: text)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].finalSurface, "猫")
        XCTAssertEqual(items[0].finalKana, "ねこ")
        XCTAssertEqual(items[0].finalMeaning, "cat")
        XCTAssertEqual(items[0].finalNote, "common")
    }
}
