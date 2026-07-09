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

    // MARK: - {ext} token + true-extension enforcement

    func testExtTokenResolvesToCameraExtension() {
        let name = CameraCapture.resolveFilename(
            pattern: "IMG_{seq}.{ext}", timestamp: Date(), sequence: 3, cameraExtension: "CR3"
        )
        XCTAssertEqual(name, "IMG_0003.CR3")
    }

    func testLiteralExtensionIsCorrectedToCameraExtension() {
        // Older installs stored a pattern hardcoding ".CR2"; an R5's CR3 must
        // not be saved under a lying extension.
        let name = CameraCapture.resolveFilename(
            pattern: "IMG_{seq}.CR2", timestamp: Date(), sequence: 3, cameraExtension: "CR3"
        )
        XCTAssertEqual(name, "IMG_0003.CR3")
    }

    func testMatchingExtensionIsKept() {
        let name = CameraCapture.resolveFilename(
            pattern: "IMG_{seq}.CR2", timestamp: Date(), sequence: 3, cameraExtension: "CR2"
        )
        XCTAssertEqual(name, "IMG_0003.CR2")
    }

    func testMissingExtensionIsAppended() {
        let name = CameraCapture.resolveFilename(
            pattern: "IMG_{seq}", timestamp: Date(), sequence: 3, cameraExtension: "JPG"
        )
        XCTAssertEqual(name, "IMG_0003.JPG")
    }

    func testNilCameraExtensionLeavesPatternAlone() {
        // Settings preview path: no camera file yet, so the literal extension
        // and the {ext} token both pass through untouched.
        let name = CameraCapture.resolveFilename(
            pattern: "IMG_{seq}.{ext}", timestamp: Date(), sequence: 3
        )
        XCTAssertEqual(name, "IMG_0003.{ext}")
    }
}
