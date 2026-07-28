import XCTest
import CoreGraphics
@testable import Scan

final class PreviewRotationTests: XCTestCase {

    // MARK: - Cycling

    func testRotateRightCyclesThroughAllFourAndWraps() {
        var r = PreviewRotation.none
        r = r.rotatedRight; XCTAssertEqual(r, .cw90)
        r = r.rotatedRight; XCTAssertEqual(r, .cw180)
        r = r.rotatedRight; XCTAssertEqual(r, .cw270)
        r = r.rotatedRight; XCTAssertEqual(r, .none)
    }

    func testRotateLeftIsTheInverseOfRotateRight() {
        for r in PreviewRotation.allCases {
            XCTAssertEqual(r.rotatedRight.rotatedLeft, r)
            XCTAssertEqual(r.rotatedLeft.rotatedRight, r)
        }
    }

    func testOnlyQuarterTurnsSwapAxes() {
        XCTAssertFalse(PreviewRotation.none.swapsAxes)
        XCTAssertTrue(PreviewRotation.cw90.swapsAxes)
        XCTAssertFalse(PreviewRotation.cw180.swapsAxes)
        XCTAssertTrue(PreviewRotation.cw270.swapsAxes)
    }

    func testDisplayAspectInvertsOnQuarterTurns() {
        let threeByTwo: CGFloat = 3.0 / 2.0
        XCTAssertEqual(PreviewRotation.none.displayAspect(sensorAspect: threeByTwo), 1.5, accuracy: 1e-9)
        XCTAssertEqual(PreviewRotation.cw180.displayAspect(sensorAspect: threeByTwo), 1.5, accuracy: 1e-9)
        XCTAssertEqual(PreviewRotation.cw90.displayAspect(sensorAspect: threeByTwo), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(PreviewRotation.cw270.displayAspect(sensorAspect: threeByTwo), 2.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - Point mapping

    /// The sensor's top-left corner is the anchor that makes the direction of
    /// rotation unambiguous: turning the image clockwise sends it to the
    /// display's top-right, then bottom-right, then bottom-left.
    func testTopLeftCornerTravelsClockwise() {
        let topLeft = CGPoint(x: 0, y: 0)
        assertPoint(PreviewRotation.none.displayPoint(fromSensor: topLeft), CGPoint(x: 0, y: 0))
        assertPoint(PreviewRotation.cw90.displayPoint(fromSensor: topLeft), CGPoint(x: 1, y: 0))
        assertPoint(PreviewRotation.cw180.displayPoint(fromSensor: topLeft), CGPoint(x: 1, y: 1))
        assertPoint(PreviewRotation.cw270.displayPoint(fromSensor: topLeft), CGPoint(x: 0, y: 1))
    }

    func testSensorAndDisplayPointMappingsRoundTrip() {
        let samples = [
            CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.13, y: 0.87), CGPoint(x: 0.99, y: 0.01),
        ]
        for r in PreviewRotation.allCases {
            for p in samples {
                assertPoint(r.sensorPoint(fromDisplay: r.displayPoint(fromSensor: p)), p)
                assertPoint(r.displayPoint(fromSensor: r.sensorPoint(fromDisplay: p)), p)
            }
        }
    }

    /// `sensorDelta` must be exactly the linear part of `sensorPoint`, or arrow
    /// keys would drift away from where a drag to the same place would land.
    func testSensorDeltaMatchesTheLinearPartOfThePointMapping() {
        let origin = CGPoint(x: 0.4, y: 0.6)
        let deltas = [
            CGVector(dx: 0, dy: -0.1), CGVector(dx: 0, dy: 0.1),
            CGVector(dx: -0.1, dy: 0), CGVector(dx: 0.1, dy: 0),
        ]
        for r in PreviewRotation.allCases {
            let mappedOrigin = r.sensorPoint(fromDisplay: origin)
            for d in deltas {
                let moved = CGPoint(x: origin.x + d.dx, y: origin.y + d.dy)
                let mappedMoved = r.sensorPoint(fromDisplay: moved)
                let expected = CGVector(dx: mappedMoved.x - mappedOrigin.x,
                                        dy: mappedMoved.y - mappedOrigin.y)
                let actual = r.sensorDelta(fromDisplay: d)
                XCTAssertEqual(actual.dx, expected.dx, accuracy: 1e-9,
                               "dx mismatch at \(r) for \(d)")
                XCTAssertEqual(actual.dy, expected.dy, accuracy: 1e-9,
                               "dy mismatch at \(r) for \(d)")
            }
        }
    }

    /// On-screen "up" must keep meaning up regardless of rotation. At cw90 the
    /// sensor's left edge is displayed along the top, so screen-up is sensor-left.
    func testScreenUpMapsToSensorLeftAtCW90() {
        let up = CGVector(dx: 0, dy: -1)
        let mapped = PreviewRotation.cw90.sensorDelta(fromDisplay: up)
        XCTAssertEqual(mapped.dx, -1, accuracy: 1e-9)
        XCTAssertEqual(mapped.dy, 0, accuracy: 1e-9)
    }

    // MARK: - Bitmap rotation

    func testRotationSwapsPixelDimensionsOnQuarterTurnsOnly() throws {
        let src = try makeImage(width: 4, height: 2, redAt: (0, 0))
        XCTAssertEqual(dimensions(try XCTUnwrap(PreviewRotation.none.rotate(src))), Dim(4, 2))
        XCTAssertEqual(dimensions(try XCTUnwrap(PreviewRotation.cw90.rotate(src))), Dim(2, 4))
        XCTAssertEqual(dimensions(try XCTUnwrap(PreviewRotation.cw180.rotate(src))), Dim(4, 2))
        XCTAssertEqual(dimensions(try XCTUnwrap(PreviewRotation.cw270.rotate(src))), Dim(2, 4))
    }

    /// The pixel-level counterpart of `testTopLeftCornerTravelsClockwise`. This
    /// is what actually pins down the sign of the rotation angle in the CGContext
    /// (which is y-up, so a visual clockwise turn is a *negative* angle).
    func testRotationMovesTheMarkedPixelClockwise() throws {
        let src = try makeImage(width: 4, height: 2, redAt: (0, 0))   // top-left

        let r90 = try XCTUnwrap(PreviewRotation.cw90.rotate(src))     // 2×4
        XCTAssertEqual(findRedPixel(r90), Pixel(1, 0), "cw90 should land top-right")

        let r180 = try XCTUnwrap(PreviewRotation.cw180.rotate(src))   // 4×2
        XCTAssertEqual(findRedPixel(r180), Pixel(3, 1), "cw180 should land bottom-right")

        let r270 = try XCTUnwrap(PreviewRotation.cw270.rotate(src))   // 2×4
        XCTAssertEqual(findRedPixel(r270), Pixel(0, 3), "cw270 should land bottom-left")
    }

    func testFourQuarterTurnsReturnToTheOriginalPixelLayout() throws {
        let src = try makeImage(width: 4, height: 2, redAt: (1, 0))
        var img = src
        for _ in 0..<4 { img = try XCTUnwrap(PreviewRotation.cw90.rotate(img)) }
        XCTAssertEqual(dimensions(img), Dim(4, 2))
        XCTAssertEqual(findRedPixel(img), Pixel(1, 0))
    }

    func testNoneReturnsTheSameImage() throws {
        let src = try makeImage(width: 4, height: 2, redAt: (0, 0))
        XCTAssertTrue(PreviewRotation.none.rotate(src) === src)
    }

    // MARK: - Helpers

    private struct Dim: Equatable { let w, h: Int; init(_ w: Int, _ h: Int) { self.w = w; self.h = h } }
    private struct Pixel: Equatable, CustomStringConvertible {
        let x, y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
        var description: String { "(\(x),\(y))" }
    }

    private func dimensions(_ cg: CGImage) -> Dim { Dim(cg.width, cg.height) }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, file: file, line: line)
    }

    /// Black image with one red pixel, addressed **top-down** so the test reads
    /// the way the image looks. CGContext is y-up, hence the row flip.
    private func makeImage(width: Int, height: Int, redAt: (x: Int, y: Int)) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: redAt.x, y: height - 1 - redAt.y, width: 1, height: 1))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// Locate the red pixel in **top-down** coordinates, or nil if absent.
    /// Re-renders into a known RGBA layout so we never depend on the source's
    /// internal byte order.
    private func findRedPixel(_ cg: CGImage) -> Pixel? {
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // CGImage scanlines are top-down: buffer row 0 is the top of the image.
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if bytes[i] > 200, bytes[i + 1] < 60, bytes[i + 2] < 60 {
                    return Pixel(x, y)
                }
            }
        }
        return nil
    }
}
