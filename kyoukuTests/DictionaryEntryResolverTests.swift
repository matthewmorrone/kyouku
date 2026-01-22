import XCTest
@testable import kyouku

final class DictionaryEntryResolverTests: XCTestCase {
    func testPrefersCanonicalFormOverVariantSpellingWhenReadingSame() {
        let surface = "合える"
        let reading = "あえる"

        // Candidate A: canonical 合える
        let entryA = DictionaryEntry(entryID: 1, kanji: "合える", kana: reading, gloss: "can do together", isCommon: true)
        let detailA = DictionaryEntryDetail(
            entryID: 1,
            isCommon: true,
            kanjiForms: [DictionaryEntryForm(id: 10, text: "合える", isCommon: true, tags: [])],
            kanaForms: [DictionaryEntryForm(id: 11, text: reading, isCommon: true, tags: [])],
            senses: []
        )

        // Candidate B: canonical 和える, but surface appears only as a non-common orthographic variant.
        let entryB = DictionaryEntry(entryID: 2, kanji: "合える", kana: reading, gloss: "to dress (vegetables, salad, etc.)", isCommon: true)
        let detailB = DictionaryEntryDetail(
            entryID: 2,
            isCommon: true,
            kanjiForms: [
                DictionaryEntryForm(id: 20, text: "和える", isCommon: true, tags: []),
                DictionaryEntryForm(id: 21, text: "合える", isCommon: false, tags: ["rK"])
            ],
            kanaForms: [DictionaryEntryForm(id: 22, text: reading, isCommon: true, tags: [])],
            senses: []
        )

        let picked = DictionaryEntryResolver.chooseBest(
            surface: surface,
            reading: reading,
            candidates: [entryB, entryA],
            detailsByEntryID: [1: detailA, 2: detailB],
            entryPriority: [1: 50, 2: 0] // Even if B has better global priority, variant penalty should keep it below A.
        )

        XCTAssertEqual(picked?.entryID, 1)
    }

    func testUsesCommonMatchedFormWhenBothExactMatch() {
        let surface = "合える"
        let reading = "あえる"

        let entryCommon = DictionaryEntry(entryID: 10, kanji: surface, kana: reading, gloss: "common", isCommon: true)
        let detailCommon = DictionaryEntryDetail(
            entryID: 10,
            isCommon: true,
            kanjiForms: [DictionaryEntryForm(id: 100, text: surface, isCommon: true, tags: [])],
            kanaForms: [DictionaryEntryForm(id: 101, text: reading, isCommon: true, tags: [])],
            senses: []
        )

        let entryRare = DictionaryEntry(entryID: 11, kanji: surface, kana: reading, gloss: "rare", isCommon: true)
        let detailRare = DictionaryEntryDetail(
            entryID: 11,
            isCommon: true,
            kanjiForms: [DictionaryEntryForm(id: 110, text: surface, isCommon: false, tags: ["rK"])],
            kanaForms: [DictionaryEntryForm(id: 111, text: reading, isCommon: true, tags: [])],
            senses: []
        )

        let picked = DictionaryEntryResolver.chooseBest(
            surface: surface,
            reading: reading,
            candidates: [entryRare, entryCommon],
            detailsByEntryID: [10: detailCommon, 11: detailRare],
            entryPriority: [10: 200, 11: 0]
        )

        XCTAssertEqual(picked?.entryID, 10)
    }
}
