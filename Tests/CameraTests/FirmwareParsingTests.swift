import XCTest
@testable import Camera

final class FirmwareParsingTests: XCTestCase {

    func testParsesStandardSummary() {
        let summary = """
        Manufacturer: Canon
        Model: EOS 7D
        Device Version: Canon EOS 7D
        Serial Number: 0000000000

        Firmware Version: 2.0.6
        """
        XCTAssertEqual(CameraSession.parseFirmware(from: summary), "2.0.6")
    }

    func testParsesAlternativeFormat() {
        let summary = "Firmware: 2.0.3"
        XCTAssertEqual(CameraSession.parseFirmware(from: summary), "2.0.3")
    }

    func testReturnsNilOnNoMatch() {
        let summary = "Model: EOS 7D\nFirmware: unknown"
        XCTAssertNil(CameraSession.parseFirmware(from: summary))
    }

    func test_7D_2_0_6_isAcceptable() {
        XCTAssertFalse(CameraSession.isFirmwareTooOld("2.0.6"))
    }

    func test_7D_2_0_3_isTooOld() {
        // Specific buggy firmware, gphoto2 issue #460.
        XCTAssertTrue(CameraSession.isFirmwareTooOld("2.0.3"))
    }

    func test_70D_typical_firmware_isAcceptable() {
        // The 70D ships firmware in the 1.x range; should not be blocked.
        XCTAssertFalse(CameraSession.isFirmwareTooOld("1.1.5"))
        XCTAssertFalse(CameraSession.isFirmwareTooOld("1.0.4"))
    }

    func test_other_eos_versions_arePermissive() {
        XCTAssertFalse(CameraSession.isFirmwareTooOld("3.0.0"))
        XCTAssertFalse(CameraSession.isFirmwareTooOld("2.0.5"))
    }

    func testMalformedFirmwareIsAcceptedByDefault() {
        XCTAssertFalse(CameraSession.isFirmwareTooOld("2.0"))
        XCTAssertFalse(CameraSession.isFirmwareTooOld(""))
    }
}
