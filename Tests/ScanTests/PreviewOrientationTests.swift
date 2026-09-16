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

    func testMirrorComesBeforeTheTurn() {
        let o = PreviewOrientation(rotation: .none, mirrored: true)
        XCTAssertEqual(o.displayPoint(fromSensor: CGPoint(x: 0.2, y: 0.7)), CGPoint(x: 0.8, y: 0.7))
        // Mirror first: the sensor's top-left becomes its top-right (1,0);
        // then a cw90 turn sends (1,0) to (1,1), the display's bottom-right.
        // The other order would land it top-left — a half turn away, which
        // is the archive's complaint about the preview.
        let m = PreviewOrientation(rotation: .cw90, mirrored: true)
        XCTAssertEqual(m.displayPoint(fromSensor: .zero), CGPoint(x: 1, y: 1))
    }

    /// flop then rot90 on a 4×4 with a mark at (0,0): the mark lands at (3,3);
    /// rot90 then flop leaves it at (0,0). The two orders differ by rot180.
    func testAgreesWithTheArchiveOnAMarkedPixel() throws {
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        bytes[0] = 255   // mark: blue channel of pixel (0,0)
        let cg = try XCTUnwrap(bytes.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
        })
        let out = try XCTUnwrap(PreviewOrientation(rotation: .cw90, mirrored: true).apply(cg))
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        let bpr = out.bytesPerRow
        func blue(_ x: Int, _ y: Int) -> UInt8 { data[y * bpr + x * 4] }
        XCTAssertEqual(blue(3, 3), 255, "the archive's order puts the mark at +3+3")
        XCTAssertEqual(blue(0, 0), 0)
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

    func testMirrorToggledDisplayRect() {
        let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        // Unturned: the mirror reads left-to-right on screen.
        let flat = PreviewOrientation(rotation: .none, mirrored: true).mirrorToggledDisplayRect(r)
        XCTAssertEqual(flat.minX, 0.6, accuracy: 1e-12)
        XCTAssertEqual(flat.minY, 0.2)
        // Turned a quarter: the same sensor mirror reads top-to-bottom.
        let turned = PreviewOrientation(rotation: .cw90, mirrored: true).mirrorToggledDisplayRect(r)
        XCTAssertEqual(turned.minX, 0.1)
        XCTAssertEqual(turned.minY, 0.4, accuracy: 1e-12)
        XCTAssertEqual(turned.height, 0.4, accuracy: 1e-12)
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
