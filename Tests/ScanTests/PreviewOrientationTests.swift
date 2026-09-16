import XCTest
import CoreGraphics
@testable import Scan

final class PreviewOrientationTests: XCTestCase {
    func testUnmirroredMatchesRotation() {
        for r in PreviewRotation.allCases {
            let o = PreviewOrientation(rotation: r, mirrored: false)
            let p = CGPoint(x: 0.2, y: 0.7)
            XCTAssertEqual(o.displayPoint(fromSensor: p), r.displayPoint(fromSensor: p))
            XCTAssertEqual(o.sensorPoint(fromDisplay: p), r.sensorPoint(fromDisplay: p))
        }
    }

    func testMirrorReflectsLeftToRightAfterTheTurn() {
        let o = PreviewOrientation(rotation: .none, mirrored: true)
        XCTAssertEqual(o.displayPoint(fromSensor: CGPoint(x: 0.2, y: 0.7)), CGPoint(x: 0.8, y: 0.7))
        // The sensor's top-left goes to the display's top-right under a cw90
        // turn; mirrored, it comes back to the top-left.
        let m = PreviewOrientation(rotation: .cw90, mirrored: true)
        XCTAssertEqual(m.displayPoint(fromSensor: .zero), CGPoint(x: 0, y: 0))
    }

    func testRoundTrip() {
        for r in PreviewRotation.allCases {
            for mirrored in [false, true] {
                let o = PreviewOrientation(rotation: r, mirrored: mirrored)
                let p = CGPoint(x: 0.3, y: 0.9)
                let back = o.sensorPoint(fromDisplay: o.displayPoint(fromSensor: p))
                XCTAssertEqual(back.x, p.x, accuracy: 1e-12)
                XCTAssertEqual(back.y, p.y, accuracy: 1e-12)
                let rect = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
                let rectBack = o.sensorRect(fromDisplay: o.displayRect(fromSensor: rect))
                XCTAssertEqual(rectBack.minX, rect.minX, accuracy: 1e-12)
                XCTAssertEqual(rectBack.width, rect.width, accuracy: 1e-12)
            }
        }
    }

    func testDeltaReversesOnlyLeftRight() {
        let o = PreviewOrientation(rotation: .none, mirrored: true)
        let d = o.sensorDelta(fromDisplay: CGVector(dx: 1, dy: 2))
        XCTAssertEqual(d, CGVector(dx: -1, dy: 2))
    }

    func testMirrorDisplayRect() {
        let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let m = PreviewOrientation.mirrorDisplayRect(r)
        XCTAssertEqual(m.minX, 0.6, accuracy: 1e-12)
        XCTAssertEqual(m.width, 0.3, accuracy: 1e-12)
        XCTAssertEqual(m.minY, 0.2)
        let back = PreviewOrientation.mirrorDisplayRect(m)
        XCTAssertEqual(back.minX, r.minX, accuracy: 1e-12)
        XCTAssertEqual(back.width, r.width, accuracy: 1e-12)
    }

    /// Two pixels, red then blue; mirrored, blue then red.
    func testMirrorsPixels() throws {
        var bytes: [UInt8] = [0, 0, 255, 255,   255, 0, 0, 255]   // BGRA little-endian: red, blue
        let cg = try XCTUnwrap(bytes.withUnsafeMutableBytes { buf -> CGImage? in
            let ctx = CGContext(data: buf.baseAddress, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            return ctx?.makeImage()
        })
        let out = try XCTUnwrap(PreviewOrientation.mirror(cg))
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        // First pixel is now the blue one.
        XCTAssertEqual(data[0], 255, "blue channel first")
        XCTAssertEqual(data[2], 0)
        XCTAssertEqual(data[4], 0)
        XCTAssertEqual(data[6], 255, "red channel second")
    }
}
