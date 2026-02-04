import XCTest
@testable import kyouku

final class DeinflectorTests: XCTestCase {
    func testExampleDeinflections() throws {
        // Load the current minimal rule-set from the repo file to avoid relying on Bundle resource wiring.
        let thisFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let rulesURL = repoRoot.appendingPathComponent("kyouku/Resources/deinflect.min.json")

        let data = try Data(contentsOf: rulesURL)
        let decoded = try JSONDecoder().decode([String: [Deinflector.Rule]].self, from: data)
        let deinflector = Deinflector(rulesByReason: decoded)

        func assertContains(_ surface: String, expected: String, file: StaticString = #filePath, line: UInt = #line) {
            let cands = deinflector.deinflect(surface, maxDepth: 8, maxResults: 64)
            XCTAssertTrue(cands.contains(where: { $0.baseForm == expected }), "Expected deinflections of '\(surface)' to include '\(expected)'", file: file, line: line)
        }

        assertContains("抱きしめて", expected: "抱きしめる")
        assertContains("包まれたい", expected: "包まれる")
        // Note: This form typically requires the boundary model to avoid including trailing particles.
        assertContains("辞めない", expected: "辞める")
        assertContains("くれなくて", expected: "くれる")
        assertContains("広げれば", expected: "広げる")
        assertContains("盗んで", expected: "盗む")
        assertContains("愛している", expected: "愛する")

        // Nominalization and causative helpers used by the hard-stop merger.
        assertContains("愛しさ", expected: "愛しい")
        assertContains("なりたくて", expected: "なる")
        assertContains("覗かせて", expected: "覗く")
    }
}
