import XCTest
@testable import Camera

final class WritableInModeTests: XCTestCase {

    func testManualModeAllWritable() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "M"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "shutterspeed", inMode: "M"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "aperture", inMode: "M"))
    }

    func testAvModeApertureWritableShutterReadOnly() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "Av"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "aperture", inMode: "Av"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "shutterspeed", inMode: "Av"))
    }

    func testTvModeShutterWritableApertureReadOnly() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "Tv"))
        XCTAssertTrue(CameraProperties.isWritable(prop: "shutterspeed", inMode: "Tv"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "aperture", inMode: "Tv"))
    }

    func testPModeShutterAndApertureBothReadOnly() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "iso", inMode: "P"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "shutterspeed", inMode: "P"))
        XCTAssertFalse(CameraProperties.isWritable(prop: "aperture", inMode: "P"))
    }

    func testUnknownPropDefaultsToWritable() {
        XCTAssertTrue(CameraProperties.isWritable(prop: "magicProperty", inMode: "Av"))
    }
}
