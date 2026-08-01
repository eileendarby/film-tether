import XCTest
import CoreGraphics
@testable import Scan

final class FrameRegionTests: XCTestCase {

    private let width = 240
    private let height = 180

    /// A mask with `rect` (normalized, y-down) set.
    private func mask(_ rects: [CGRect], extra: [(Int, Int)] = []) -> [Bool] {
        var m = [Bool](repeating: false, count: width * height)
        for r in rects {
            let x0 = Int(r.minX * Double(width)), x1 = Int(r.maxX * Double(width))
            let y0 = Int(r.minY * Double(height)), y1 = Int(r.maxY * Double(height))
            for y in max(0, y0)..<min(height, y1) {
                for x in max(0, x0)..<min(width, x1) { m[y * width + x] = true }
            }
        }
        for (x, y) in extra where x >= 0 && x < width && y >= 0 && y < height {
            m[y * width + x] = true
        }
        return m
    }

    private func detect(_ m: [Bool], at centre: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> FrameRegion.Result? {
        FrameRegion.detect(mask: m, width: width, height: height, around: centre)
    }

    // MARK: - Growing

    func testFindsARectangularRegion() throws {
        let frame = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let r = try XCTUnwrap(detect(mask([frame])))
        XCTAssertEqual(r.center.x, frame.midX, accuracy: 0.02)
        XCTAssertEqual(r.center.y, frame.midY, accuracy: 0.02)
        XCTAssertEqual(r.size.width, frame.width, accuracy: 0.04)
        XCTAssertEqual(r.size.height, frame.height, accuracy: 0.04)
        XCTAssertFalse(r.touchesBorder)
    }

    /// The reason for growing from the centre rather than taking the largest
    /// region: on a strip the largest is the wrong answer, or several frames
    /// joined together.
    func testPicksTheRegionUnderTheLensNotTheLargest() throws {
        let small = CGRect(x: 0.40, y: 0.30, width: 0.20, height: 0.40)   // contains the centre
        let large = CGRect(x: 0.68, y: 0.05, width: 0.30, height: 0.90)   // bigger, elsewhere
        let r = try XCTUnwrap(detect(mask([small, large])))
        XCTAssertEqual(r.center.x, small.midX, accuracy: 0.03,
                       "grew the largest region instead of the one under the lens")
        XCTAssertLessThan(r.size.width, 0.30)
    }

    func testStartingPointSelectsTheRegion() throws {
        let left = CGRect(x: 0.05, y: 0.30, width: 0.25, height: 0.40)
        let right = CGRect(x: 0.65, y: 0.30, width: 0.25, height: 0.40)
        let m = mask([left, right])
        let a = try XCTUnwrap(detect(m, at: CGPoint(x: 0.17, y: 0.5)))
        let b = try XCTUnwrap(detect(m, at: CGPoint(x: 0.78, y: 0.5)))
        XCTAssertEqual(a.center.x, left.midX, accuracy: 0.03)
        XCTAssertEqual(b.center.x, right.midX, accuracy: 0.03)
    }

    /// A speck under the lens shouldn't cost the detection: the seed walks out
    /// to the nearest masked pixel.
    func testASingleUnmaskedPixelAtTheCentreIsSurvivable() throws {
        var m = mask([CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)])
        m[(height / 2) * width + (width / 2)] = false
        let r = try XCTUnwrap(detect(m))
        XCTAssertEqual(r.size.width, 0.50, accuracy: 0.05)
    }

    func testReportsWhenTheRegionRunsOffThePicture() throws {
        let r = try XCTUnwrap(detect(mask([CGRect(x: -0.1, y: 0.2, width: 0.6, height: 0.6)])))
        XCTAssertTrue(r.touchesBorder)
    }

    func testRefusesWhenTheMaskCoversNearlyEverything() {
        XCTAssertNil(detect(mask([CGRect(x: 0, y: 0, width: 1, height: 1)])))
    }

    func testRefusesAnEmptyMask() {
        XCTAssertNil(detect([Bool](repeating: false, count: width * height)))
    }

    // MARK: - Morphology

    /// Dust and scratches survive any threshold; opening is what removes them,
    /// and it must not move the frame's own edges while doing it.
    func testSpecklesAreRemovedWithoutShrinkingTheFrame() throws {
        let frame = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let specks = [(10, 10), (12, 40), (200, 20), (30, 160), (220, 170)]
        let clean = try XCTUnwrap(detect(mask([frame])))
        let dirty = try XCTUnwrap(detect(mask([frame], extra: specks)))
        XCTAssertEqual(dirty.size.width, clean.size.width, accuracy: 0.01)
        XCTAssertEqual(dirty.size.height, clean.size.height, accuracy: 0.01)
    }

    /// Opening also breaks the thin bridges that let a region leak into its
    /// neighbour through a separator that erosion has nearly closed.
    func testAThinBridgeDoesNotJoinTwoFrames() throws {
        let here = CGRect(x: 0.20, y: 0.30, width: 0.25, height: 0.40)
        let next = CGRect(x: 0.60, y: 0.30, width: 0.25, height: 0.40)
        // A one-pixel bridge between them.
        let y = height / 2
        let bridge = (Int(0.45 * Double(width))..<Int(0.60 * Double(width))).map { ($0, y) }
        let r = try XCTUnwrap(detect(mask([here, next], extra: bridge),
                                     at: CGPoint(x: 0.32, y: 0.5)))
        XCTAssertLessThan(r.size.width, 0.35, "leaked across the bridge into the next frame")
    }

    // MARK: - Rotation

    /// The point of an oriented rectangle: a negative a degree or two off square
    /// should be measured as the rectangle it is, not the larger upright box
    /// that contains it.
    func testMeasuresARotatedFrame() throws {
        let angle = 4.0 * .pi / 180
        let halfW = 0.22 * Double(width), halfH = 0.28 * Double(height)
        var m = [Bool](repeating: false, count: width * height)
        let cx = Double(width) / 2, cy = Double(height) / 2
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx, dy = Double(y) - cy
                let u = dx * cos(angle) + dy * sin(angle)
                let v = -dx * sin(angle) + dy * cos(angle)
                if abs(u) <= halfW, abs(v) <= halfH { m[y * width + x] = true }
            }
        }
        let r = try XCTUnwrap(detect(m))
        XCTAssertEqual(abs(r.angle), 4.0, accuracy: 1.0, "rotation not recovered")
        // The oriented size must be the true one, not the upright box's.
        XCTAssertEqual(r.size.width * Double(width), halfW * 2, accuracy: 6)
        XCTAssertEqual(r.size.height * Double(height), halfH * 2, accuracy: 6)
        // And the upright box it reports must be bigger than the frame itself.
        XCTAssertGreaterThan(r.boundingRect.width, r.size.width)
    }

    func testAnUnrotatedFrameReportsNoRotation() throws {
        let r = try XCTUnwrap(detect(mask([CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)])))
        XCTAssertEqual(r.angle, 0, accuracy: 0.6)
    }

    // MARK: - Band

    func testBandContains() {
        let b = FrameRegion.Band(low: 0.2, high: 0.6)
        XCTAssertFalse(b.contains(0.1))
        XCTAssertTrue(b.contains(0.4))
        XCTAssertFalse(b.contains(0.7))
    }

    func testBandToleratesReversedBounds() {
        let b = FrameRegion.Band(low: 0.6, high: 0.2)
        XCTAssertEqual(b.low, 0.2, accuracy: 1e-9)
        XCTAssertEqual(b.high, 0.6, accuracy: 1e-9)
    }
}
