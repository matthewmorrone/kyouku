//
//  kyoukuTests.swift
//  kyoukuTests
//
//  Created by Matthew Morrone on 12/22/25.
//

import Testing
import XCTest
@testable import kyouku

struct kyoukuTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

final class SearchViewModelFilterSortTests: XCTestCase {
    func testDefaultControlsPreserveInputOrder() {
        let rows = [
            makeRow(surface: "食べる", isCommon: true),
            makeRow(surface: "書く", isCommon: false),
            makeRow(surface: "行く", isCommon: true)
        ]

        let output = SearchViewModel.applyFiltersAndSort(to: rows, controls: .default)

        XCTAssertEqual(output.map(\.id), rows.map(\.id))
    }

    func testCommonWordsOnlyFiltersNonCommonRows() {
        let rows = [
            makeRow(surface: "食べる", isCommon: true),
            makeRow(surface: "稀語", isCommon: false)
        ]
        var controls = SearchViewModel.ResultControls.default
        controls.commonWordsOnly = true

        let output = SearchViewModel.applyFiltersAndSort(to: rows, controls: controls)

        XCTAssertEqual(output.map(\.surface), ["食べる"])
    }

    func testCommonFirstSortIsStableForTies() {
        let rows = [
            makeRow(surface: "rare-1", isCommon: false),
            makeRow(surface: "common-1", isCommon: true),
            makeRow(surface: "rare-2", isCommon: false),
            makeRow(surface: "common-2", isCommon: true)
        ]
        var controls = SearchViewModel.ResultControls.default
        controls.sortMode = .commonFirst

        let output = SearchViewModel.applyFiltersAndSort(to: rows, controls: controls)

        XCTAssertEqual(output.map(\.surface), ["common-1", "common-2", "rare-1", "rare-2"])
    }

    func testAlphabeticalSortUsesSurface() {
        let rows = [
            makeRow(surface: "ねこ", isCommon: true),
            makeRow(surface: "いぬ", isCommon: true),
            makeRow(surface: "さる", isCommon: true)
        ]
        var controls = SearchViewModel.ResultControls.default
        controls.sortMode = .alphabetical

        let output = SearchViewModel.applyFiltersAndSort(to: rows, controls: controls)

        XCTAssertEqual(output.map(\.surface), ["いぬ", "さる", "ねこ"])
    }

    func testPartOfSpeechAndJLPTFiltersCompose() {
        let rows = [
            makeRow(surface: "食べる", isCommon: true, partsOfSpeech: [.verb], jlpt: .n5),
            makeRow(surface: "赤い", isCommon: true, partsOfSpeech: [.adjective], jlpt: .n5),
            makeRow(surface: "熟達", isCommon: true, partsOfSpeech: [.noun], jlpt: .n1)
        ]
        var controls = SearchViewModel.ResultControls.default
        controls.selectedPartsOfSpeech = [.verb, .adjective]
        controls.selectedJLPT = .n5

        let output = SearchViewModel.applyFiltersAndSort(to: rows, controls: controls)

        XCTAssertEqual(output.map(\.surface), ["食べる", "赤い"])
    }

    func testBuilderInfersPartOfSpeechAndJLPTFromDetails() {
        let entry = DictionaryEntry(entryID: 42, kanji: "食べる", kana: "たべる", gloss: "to eat", isCommon: true)
        let detail = DictionaryEntryDetail(
            entryID: 42,
            isCommon: true,
            kanjiForms: [
                DictionaryEntryForm(id: 1, text: "食べる", isCommon: true, tags: ["jlpt5"]) 
            ],
            kanaForms: [
                DictionaryEntryForm(id: 2, text: "たべる", isCommon: true, tags: [])
            ],
            senses: [
                DictionaryEntrySense(
                    id: 3,
                    orderIndex: 0,
                    partsOfSpeech: ["v1"],
                    miscellaneous: [],
                    fields: [],
                    dialects: [],
                    glosses: [DictionarySenseGloss(id: 4, text: "to eat", language: "eng", orderIndex: 0)]
                )
            ]
        )

        let builder = DictionaryResultRow.Builder(surface: "食べる", kanaKey: "たべる", entries: [entry])
        let row = builder.build(firstGlossFor: { $0.gloss }, detailForEntryID: { _ in detail })

        XCTAssertEqual(row?.partsOfSpeech, [.verb])
        XCTAssertEqual(row?.jlptLevel, .n5)
    }

    private func makeRow(
        surface: String,
        isCommon: Bool,
        partsOfSpeech: Set<DictionaryPartOfSpeech> = [],
        jlpt: DictionaryJLPTLevel? = nil
    ) -> DictionaryResultRow {
        DictionaryResultRow(
            surface: surface,
            kana: nil,
            gloss: "",
            isCommon: isCommon,
            partsOfSpeech: partsOfSpeech,
            jlptLevel: jlpt
        )
    }
}
