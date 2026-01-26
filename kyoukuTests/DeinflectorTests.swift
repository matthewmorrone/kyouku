import XCTest
@testable import kyouku

final class DeinflectorTests: XCTestCase {
    func testExampleDeinflections() throws {
        // Use the bundled minimal rule-set (a subset copied verbatim from Yomichan's deinflect.json).
        let deinflector = try Deinflector.loadBundled(named: "deinflect")

        func assertContains(_ surface: String, expected: String, file: StaticString = #filePath, line: UInt = #line) {
            let cands = deinflector.deinflect(surface, maxDepth: 8, maxResults: 64)
            XCTAssertTrue(cands.contains(where: { $0.baseForm == expected }), "Expected deinflections of '\(surface)' to include '\(expected)'", file: file, line: line)
        }

        assertContains("抱きしめて", expected: "抱きしめる")
        assertContains("包まれたい", expected: "包まれる")
        // Note: This form typically requires the boundary model to avoid including trailing particles.
        assertContains("辞めない", expected: "辞める")
        assertContains("広げれば", expected: "広げる")
        assertContains("盗んで", expected: "盗む")
        assertContains("愛している", expected: "愛する")
    }
}
