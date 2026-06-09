import XCTest
@testable import Camera

final class FilenameTemplateTests: XCTestCase {

    func testFullPattern() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 23
        comps.hour = 14; comps.minute = 35; comps.second = 7
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        let name = CameraCapture.resolveFilename(
            pattern: "IMG_{ymd}_{hms}_{seq}.CR2",
            timestamp: date,
            sequence: 42
        )
        XCTAssertEqual(name, "IMG_20260523_143507_0042.CR2")
    }

    func testSequenceZeroPad() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(
            CameraCapture.resolveFilename(pattern: "{seq}", timestamp: date, sequence: 7).hasSuffix("0007")
        )
        XCTAssertEqual(
            CameraCapture.resolveFilename(pattern: "{seq}", timestamp: date, sequence: 9999),
            "9999"
        )
    }

    func testPatternWithoutTokensIsUnchanged() {
        XCTAssertEqual(
            CameraCapture.resolveFilename(pattern: "static.CR2", timestamp: Date(), sequence: 1),
            "static.CR2"
        )
    }
}
