import XCTest
@testable import kyouku

final class ReadingOverridePolicyTests: XCTestCase {
    func testOverrideAppliesWhenDictionaryDiffers() async {
        let policy = ReadingOverridePolicy(loader: {
            [SurfaceReadingOverride(surface: "虹色", reading: "ニジイロ")]
        })

        let reading = await policy.overrideReading(for: "虹色", mecabReading: "にじしょく")
        XCTAssertEqual(reading, "にじいろ")
    }

    func testOverrideSkipsWhenReadingsMatch() async {
        let policy = ReadingOverridePolicy(loader: {
            [SurfaceReadingOverride(surface: "虹色", reading: "ニジイロ")]
        })

        let reading = await policy.overrideReading(for: "虹色", mecabReading: "にじいろ")
        XCTAssertNil(reading)
    }

    func testOverrideProvidesReadingWhenMeCabMissing() async {
        let policy = ReadingOverridePolicy(loader: {
            [SurfaceReadingOverride(surface: "虹色", reading: "ニジイロ")]
        })

        let reading = await policy.overrideReading(for: "虹色", mecabReading: nil)
        XCTAssertEqual(reading, "にじいろ")
    }
}
