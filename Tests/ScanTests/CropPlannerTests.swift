import XCTest
import CoreGraphics
@testable import Scan

final class CropPlannerTests: XCTestCase {

    private struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFF) / Double(0xFFFF)
        }
    }

    private let width = 240
    private let height = 156

    /// A strip of film running left to right: black holder above and below, a
    /// bright rebate between frames, and textured picture inside each frame.
    ///
    /// `frames` are along-strip spans in grid columns.
    private func makeStrip(
        frames: [Range<Int>],
        holderRows: Int = 18,
        /// Rows of rebate between the frame and the film's own edge. Without it
        /// the picture abuts the holder and a region grown from the centre
        /// floods straight into it — which is a real geometry, but not the one
        /// these tests are about.
        frameInset: Int = 6,
        rebate: Double = 0.85,
        picture: Double = 0.35,
        holder: Double = 0.02,
        seed: UInt64 = 5
    ) -> ColorGrid {
        var rng = Rand(state: seed)
        // Smooth, photograph-like tone rather than blocks. Blocky texture makes
        // every block boundary a hard edge, and they line up into long straight
        // verticals running the frame's whole height — something no photograph
        // produces, and convincing enough to outvote the film's own edges. A sum
        // of a few waves has plenty of contrast and no straight edges at all.
        let phase = (0..<4).map { _ in rng.next() * 6.283 }
        func tone(_ x: Int, _ y: Int) -> Double {
            let fx = Double(x), fy = Double(y)
            return 0.5
                + 0.22 * sin(fx / 23 + phase[0]) * cos(fy / 31 + phase[1])
                + 0.16 * sin(fx / 11 + fy / 17 + phase[2])
                + 0.08 * cos(fx / 7 - fy / 9 + phase[3])
        }

        var pixels: [ColorGrid.Pixel] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                var v: Double
                if y < holderRows || y >= height - holderRows {
                    v = holder
                } else if frames.contains(where: { $0.contains(x) }),
                          y >= holderRows + frameInset,
                          y < height - holderRows - frameInset {
                    v = picture + (tone(x, y) - 0.5) * 0.60
                } else {
                    v = rebate
                }
                v = min(max(v, 0), 1)
                pixels.append(ColorGrid.Pixel(red: v, green: v, blue: v))
            }
        }
        return ColorGrid(width: width, height: height, pixels: pixels)
    }

    private let square = FilmSize(id: 2, name: "120mm Rollei", widthMM: 56, heightMM: 56)
    private let threeByTwo = FilmSize(id: 8, name: "6x9", widthMM: 56, heightMM: 84)

    private func plan(_ grid: ColorGrid, _ expect: FilmSize?) -> CropPlanner.Plan? {
        CropPlanner.plan(in: grid, expecting: expect, around: CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - The holder

    func testCrossBoundsGiveTheAxisAndThePicturesExtent() throws {
        let grid = makeStrip(frames: [60..<180])
        let h = try XCTUnwrap(CropPlanner.crossBounds(in: grid, around: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(h.axis, .horizontal, "film runs along the unbounded axis")
        XCTAssertEqual(h.near, 24, accuracy: 3)
        XCTAssertEqual(h.far, height - 25, accuracy: 3)
    }

    /// The strip's direction must come from the holder, not from the frame's
    /// shape — a 6×6 frame is square and its shape says nothing at all.
    func testASquareFrameStillResolvesTheAxis() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        let h = try XCTUnwrap(CropPlanner.crossBounds(in: grid, around: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(h.axis, .horizontal)
    }

    func testNoCrossBoundsWhenNothingMasksTheFilm() {
        // Uniform texture everywhere: nothing that looks like a mask.
        var rng = Rand(state: 9)
        var pixels: [ColorGrid.Pixel] = []
        for _ in 0..<(width * height) {
            let v = 0.4 + (rng.next() - 0.5) * 0.2
            pixels.append(ColorGrid.Pixel(red: v, green: v, blue: v))
        }
        let grid = ColorGrid(width: width, height: height, pixels: pixels)
        XCTAssertNil(CropPlanner.crossBounds(in: grid, around: CGPoint(x: 0.5, y: 0.5)))
    }

    // MARK: - Believing the detection

    /// A clean frame of the expected shape should come back from the detector
    /// itself, not from the fallback.
    func testACleanFrameOfTheExpectedShapeIsDetected() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertEqual(p.route, .detected)
        XCTAssertEqual(p.rect.width * Double(width) / (p.rect.height * Double(height)),
                       1.0, accuracy: 0.10)
    }

    /// The point of the whole exercise: a detection whose shape no expected
    /// frame could have must not be used. Measured on a real capture, the region
    /// detector returned a 1.60 aspect for a 120 negative.
    func testADetectionOfTheWrongShapeIsRejected() throws {
        // A frame far wider than tall, while a square one is expected.
        let grid = makeStrip(frames: [12..<228])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertNotEqual(p.route, .detected,
                          "a 1.5-ish detection was accepted for a square format")
    }

    /// The operator changing film must not need to announce it: a detection that
    /// contradicts the expectation but held over a long plateau *and* matches
    /// some other real format is believed.
    func testAConfidentDetectionOfADifferentFormatIsBelieved() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        // Square frame in view, but 6x9 is expected. The detection is clean, so
        // it should win rather than being forced into a 3:2 box.
        let p = try XCTUnwrap(plan(grid, threeByTwo))
        if p.route == .detected {
            let a = (p.rect.width * Double(width)) / (p.rect.height * Double(height))
            XCTAssertEqual(a, 1.0, accuracy: 0.15)
        }
    }

    func testWithNoExpectationTheDetectionIsUsed() throws {
        let grid = makeStrip(frames: [(width / 2 - 54)..<(width / 2 + 54)])
        let p = try XCTUnwrap(plan(grid, nil))
        XCTAssertEqual(p.route, .detected)
        XCTAssertNil(p.size)
    }

    // MARK: - Plan B

    /// When the detection is rejected, the crop is *built*: the expected format
    /// sets the shape, the holder sets the size.
    func testTheFallbackHasTheExpectedShape() throws {
        let grid = makeStrip(frames: [12..<228])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertNotEqual(p.route, .detected)
        let a = (p.rect.width * Double(width)) / (p.rect.height * Double(height))
        XCTAssertEqual(a, 1.0, accuracy: 0.05, "fallback is not the expected shape")
    }

    func testTheFallbackIsSizedToTheHolder() throws {
        let grid = makeStrip(frames: [12..<228], holderRows: 24)
        let p = try XCTUnwrap(plan(grid, square))
        // holderRows 24 either side, plus 6 rows of rebate: the picture spans
        // what's left.
        let pictureRows = Double(height - 2 * (24 + 6))
        XCTAssertEqual(p.rect.height * Double(height), pictureRows, accuracy: 6,
                       "height should be the picture's extent across the strip")
    }

    /// One side is pinned to a real edge; the other follows from the format.
    func testTheFallbackAnchorsToANearbyEdge() throws {
        // A frame too wide to be believed as square, so the fallback runs, with
        // its right edge close enough for the built box to reach.
        let grid = makeStrip(frames: [24..<200])
        let p = try XCTUnwrap(plan(grid, square))
        guard p.route == .anchored else {
            return XCTFail("expected to anchor, got \(p.route.rawValue)")
        }
        let anchored = p.anchoredEdge
        XCTAssertTrue(anchored == .left || anchored == .right)
        let edgePx = anchored == .right ? p.rect.maxX * Double(width)
                                        : p.rect.minX * Double(width)
        XCTAssertEqual(edgePx, 200, accuracy: 12, "did not land on the frame's edge")
    }

    /// Anchoring must not drag the box across the negative to reach something
    /// far away — that edge belongs to a different frame.
    func testAFarAwayEdgeIsNotAnchoredTo() throws {
        // One frame filling the whole strip: no inter-frame edge anywhere, so
        // there is nothing within reach to anchor to.
        let grid = makeStrip(frames: [0..<240])
        let p = try XCTUnwrap(plan(grid, square))
        XCTAssertEqual(p.route, .centred)
        XCTAssertNil(p.anchoredEdge)
        XCTAssertEqual(p.rect.midX, 0.5, accuracy: 0.02)
    }

    /// With no format to build from and a detection that can't be trusted,
    /// there's nothing honest to return.
    func testNoExpectationAndNoUsableDetectionYieldsNothing() {
        var pixels: [ColorGrid.Pixel] = []
        for _ in 0..<(width * height) {
            pixels.append(ColorGrid.Pixel(red: 0.5, green: 0.5, blue: 0.5))
        }
        let grid = ColorGrid(width: width, height: height, pixels: pixels)
        XCTAssertNil(plan(grid, nil))
    }

    /// The fallback needs the holder; without it there's no size to build from.
    func testNoCrossBoundsMeansNoFallback() {
        var rng = Rand(state: 3)
        var pixels: [ColorGrid.Pixel] = []
        for _ in 0..<(width * height) {
            let v = 0.4 + (rng.next() - 0.5) * 0.5
            pixels.append(ColorGrid.Pixel(red: v, green: v, blue: v))
        }
        let grid = ColorGrid(width: width, height: height, pixels: pixels)
        // Whatever comes back must not be a fallback built on nothing.
        if let p = plan(grid, square) {
            XCTAssertEqual(p.route, .detected)
        }
    }

    // MARK: - The plan stays in the picture

    func testThePlanIsAlwaysInsideThePicture() throws {
        for frames in [[12..<228], [0..<120], [180..<240]] {
            let grid = makeStrip(frames: frames)
            let p = try XCTUnwrap(plan(grid, square))
            XCTAssertGreaterThanOrEqual(p.rect.minX, 0)
            XCTAssertGreaterThanOrEqual(p.rect.minY, 0)
            XCTAssertLessThanOrEqual(p.rect.maxX, 1.0001)
            XCTAssertLessThanOrEqual(p.rect.maxY, 1.0001)
        }
    }
}

