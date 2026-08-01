import XCTest
import CoreGraphics
@testable import Scan

final class EdgeVotingTests: XCTestCase {

    private struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFF) / Double(0xFFFF)
        }
    }

    private let width = 400
    private let height = 300

    /// Builds a grid directly rather than going through CGImage, so a test can
    /// place a one-pixel density step exactly where it says it does.
    private func makeGrid(_ body: (Int, Int) -> Double) -> ColorGrid {
        var pixels: [ColorGrid.Pixel] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = min(max(body(x, y), 0), 1)
                pixels.append(ColorGrid.Pixel(red: v, green: v, blue: v))
            }
        }
        return ColorGrid(width: width, height: height, pixels: pixels)
    }

    // MARK: - The basic claim

    /// A step down one column, buried in noise, is found because every row that
    /// crosses it votes for the same x.
    func testAStepThroughNoiseIsFound() {
        var rng = Rand(state: 7)
        var noise = [Double](repeating: 0, count: width * height)
        for i in 0..<noise.count { noise[i] = rng.next() }
        let grid = makeGrid { x, y in
            0.35 + noise[y * width + x] * 0.25 + (x >= 137 ? 0.30 : 0)
        }
        let found = EdgeVoting.candidates(in: grid, orientation: .vertical)
        let best = try? XCTUnwrap(found.first)
        XCTAssertEqual(best?.index ?? -1, 137, accuracy: 1)
        XCTAssertGreaterThan(best?.coverage ?? 0, 0.9)
    }

    /// Coverage is a fraction and must read as one. Pooling neighbouring
    /// columns sums their votes, so a thick edge can collect more votes than
    /// there are rows — measured at 104% on a real capture before this was
    /// capped.
    func testCoverageNeverExceedsOne() {
        let grid = makeGrid { x, _ in x >= 200 ? 0.8 : 0.2 }
        for c in EdgeVoting.candidates(in: grid, orientation: .vertical) {
            XCTAssertLessThanOrEqual(c.coverage, 1.0)
            XCTAssertGreaterThanOrEqual(c.coverage, 0)
        }
    }

    /// Detail that isn't aligned gets no purchase, however strong it is: that's
    /// the whole point of counting votes rather than measuring contrast.
    func testUnalignedContrastDoesNotWin() {
        var rng = Rand(state: 11)
        var jitter = [Int](repeating: 0, count: height)
        for y in 0..<height { jitter[y] = Int(rng.next() * 60) + 40 }
        let grid = makeGrid { x, y in
            // A hard step whose position wanders from row to row, plus a real
            // aligned step at 300 that is *weaker*.
            var v = 0.4
            if x >= jitter[y] { v += 0.35 }
            if x >= 300 { v += 0.10 }
            return v
        }
        let found = EdgeVoting.candidates(in: grid, orientation: .vertical)
        let best = try? XCTUnwrap(found.first)
        XCTAssertEqual(best?.index ?? -1, 300, accuracy: 1,
                       "the wandering edge outvoted the straight one")
    }

    func testHorizontalEdgesAreFoundToo() {
        var rng = Rand(state: 3)
        var noise = [Double](repeating: 0, count: width * height)
        for i in 0..<noise.count { noise[i] = rng.next() }
        let grid = makeGrid { x, y in
            0.35 + noise[y * width + x] * 0.25 + (y >= 92 ? 0.30 : 0)
        }
        let found = EdgeVoting.candidates(in: grid, orientation: .horizontal)
        XCTAssertEqual(found.first?.index ?? -1, 92, accuracy: 1)
    }

    /// A slightly rotated negative walks its edge sideways; the votes still have
    /// to land on one candidate rather than smearing across several.
    func testASlightlyTiltedEdgeStillCollectsItsVotes() {
        let grid = makeGrid { x, y in
            // Drifts one pixel over the full height.
            x >= 200 + y / 299 ? 0.75 : 0.30
        }
        let found = EdgeVoting.candidates(in: grid, orientation: .vertical)
        let best = try? XCTUnwrap(found.first)
        XCTAssertEqual(best?.index ?? -1, 200, accuracy: 1)
        XCTAssertGreaterThan(best?.coverage ?? 0, 0.9)
    }

    // MARK: - The density window

    /// The window is what makes the vote decisive when the photograph has long
    /// straight lines of its own — an interior with shelves and doorframes will
    /// align across hundreds of rows just as convincingly as the film's edge.
    ///
    /// Here a strong picture edge sits in the midtones and the film edge crosses
    /// from midtone up to base. Looking across a band above the midtones leaves
    /// only the film edge with anything to see.
    func testAWindowSuppressesEdgesOutsideItsBand() {
        let grid = makeGrid { x, _ in
            if x >= 320 { return 0.70 }      // film base
            if x >= 120 { return 0.45 }      // a strong picture edge, in midtones
            return 0.10
        }
        let band = EdgeVoting.DensityWindow(low: 0.55, high: 0.75)
        let windowed = EdgeVoting.candidates(in: grid, orientation: .vertical, window: band)
        XCTAssertEqual(windowed.count, 1, "only the transition crossing the band should survive")
        XCTAssertEqual(windowed.first?.index ?? -1, 320, accuracy: 1)

        // Without it, both edges are equally convincing and the picture's comes
        // first — which is the failure the window exists to prevent.
        let plain = EdgeVoting.candidates(in: grid, orientation: .vertical)
        XCTAssertEqual(plain.count, 2)
    }

    func testWindowClampsOutsideItsBounds() {
        let w = EdgeVoting.DensityWindow(low: 0.4, high: 0.6)
        XCTAssertEqual(w.apply(0.1), 0, accuracy: 1e-9)
        XCTAssertEqual(w.apply(0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(w.apply(0.9), 1, accuracy: 1e-9)
    }

    func testWindowAroundALevelIsCentredOnIt() {
        let w = EdgeVoting.DensityWindow(around: 0.6, width: 0.2)
        XCTAssertEqual(w.low, 0.5, accuracy: 1e-9)
        XCTAssertEqual(w.high, 0.7, accuracy: 1e-9)
    }

    /// Reversed bounds are a caller's slip, not a reason to return nonsense.
    func testWindowToleratesReversedBounds() {
        let w = EdgeVoting.DensityWindow(low: 0.8, high: 0.2)
        XCTAssertEqual(w.low, 0.2, accuracy: 1e-9)
        XCTAssertEqual(w.high, 0.8, accuracy: 1e-9)
    }

    // MARK: - Restricting where to look

    /// Only the rows crossing the film should vote, or the holder either side
    /// contributes its own edges.
    func testRestrictingTheCrossingLinesChangesWhoVotes() {
        let grid = makeGrid { x, y in
            if y < 50 || y > 250 { return x >= 80 ? 0.9 : 0.05 }   // holder, own edge at 80
            return x >= 260 ? 0.75 : 0.30                          // film, edge at 260
        }
        let all = EdgeVoting.candidates(in: grid, orientation: .vertical, minCoverage: 0.1)
        XCTAssertTrue(all.contains { abs($0.index - 80) <= 1 })

        let filmOnly = EdgeVoting.candidates(
            in: grid, orientation: .vertical, across: 50...250, minCoverage: 0.1)
        XCTAssertFalse(filmOnly.contains { abs($0.index - 80) <= 1 },
                       "the holder's edge voted despite being outside the film")
        XCTAssertTrue(filmOnly.contains { abs($0.index - 260) <= 1 })
    }

    // MARK: - Degenerate input

    func testAFlatPictureYieldsNoEdges() {
        let grid = makeGrid { _, _ in 0.5 }
        XCTAssertTrue(EdgeVoting.candidates(in: grid, orientation: .vertical).isEmpty)
    }

    func testMedianAndMADAreRobustToOutliers() {
        var values = [Double](repeating: 1.0, count: 100)
        values[0] = 500
        values[1] = -500
        let (median, mad) = EdgeVoting.medianAndMAD(values)
        XCTAssertEqual(median, 1.0, accuracy: 1e-9)
        XCTAssertEqual(mad, 0, accuracy: 1e-9)
    }
}
