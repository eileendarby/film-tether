import XCTest
@testable import Camera

final class CameraErrorTests: XCTestCase {

    func testFromMapsZeroToNil() {
        XCTAssertNil(CameraError.from(rc: 0))
    }

    func testFromMapsUSBClaim() {
        guard case .usbClaimDenied(let underlying) = CameraError.from(rc: -53)! else {
            XCTFail("expected usbClaimDenied")
            return
        }
        XCTAssertEqual(underlying, -53)
    }

    func testFromMapsGenericLibgphotoError() {
        let err = CameraError.from(rc: -1)
        if case .libGPhoto(let code, _) = err! {
            XCTAssertEqual(code, -1)
        } else {
            XCTFail("expected libGPhoto case")
        }
    }

    func testCheckThrowsOnError() {
        XCTAssertThrowsError(try CameraError.check(-1))
    }

    func testCheckDoesNotThrowOnOk() {
        XCTAssertNoThrow(try CameraError.check(0))
    }

    func testErrorDescriptionsArePopulated() {
        let cases: [CameraError] = [
            .cameraNotFound,
            .usbClaimDenied(underlying: -53),
            .propertyReadOnly(name: "shutterspeed"),
            .propertyNotFound(name: "foo"),
            .liveViewNotActive,
            .firmwareTooOld(detected: "2.0.3"),
            .captureFailed(reason: "test"),
        ]
        for c in cases {
            XCTAssertFalse(c.localizedDescription.isEmpty, "missing description for \(c)")
        }
    }
}
