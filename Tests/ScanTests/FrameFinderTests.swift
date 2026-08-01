import XCTest
import CoreGraphics
@testable import Scan

final class FrameFinderTests: XCTestCase {

    // MARK: - Building test pictures

    /// Deterministic noise, so a failure is always the same failure.
    private struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFF) / Double(0xFFFF)
        }
    }

    private let width = 768
    private let height = 576

    /// A picture of film: a flat field at `bandLevel` standing in for unexposed
    /// film, with textured rectangles standing in for exposed frames.
    ///
    /// The texture is blocky rather than per-pixel because the detector
    /// downsamples to 192 wide before measuring — per-pixel noise would average
    /// straight out, which is exactly what it's meant to do to grain and dust.
    private func makeFilm(
        frames: [CGRect],
        bandLevel: CGFloat = 0.80,
        pictureLevel: CGFloat = 0.35,
        pictureSpread: CGFloat = 0.30,
        block: Int = 16,
        /// Flat, featureless region inside the *first* frame, given as a
        /// fraction of that frame's height measured from its top. Fades in, so
        /// the picture brightens gradually into it rather than stepping.
        smoothPatch: CGFloat = 0,
        seed: UInt64 = 42
    ) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        func grey(_ v: CGFloat) -> CGColor {
            let c = min(max(v, 0), 1)
            return CGColor(colorSpace: space, components: [c, c, c, 1])!
        }
        ctx.setFillColor(grey(bandLevel))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var rng = Rand(state: seed)
        for (n, frame) in frames.enumerated() {
            let px = CGRect(x: frame.minX * CGFloat(width),
                            y: (1 - frame.maxY) * CGFloat(height),
                            width: frame.width * CGFloat(width),
                            height: frame.height * CGFloat(height))
            var y = px.minY
            while y < px.maxY {
                var x = px.minX
                // Distance from the frame's *top* edge (y-down), 0...1.
                let fromTop = 1 - (y + CGFloat(block) / 2 - px.minY) / max(px.height, 1)
                while x < px.maxX {
                    let cell = CGRect(x: x, y: y,
                                      width: min(CGFloat(block), px.maxX - x),
                                      height: min(CGFloat(block), px.maxY - y))
                    var v = pictureLevel + CGFloat(rng.next() - 0.5) * pictureSpread
                    if n == 0, smoothPatch > 0, fromTop < smoothPatch {
                        // Ramp texture out and level up towards the band, with no
                        // step anywhere — the shape that fooled a smoothness test
                        // on the real negative.
                        let t = 1 - fromTop / smoothPatch
                        v = pictureLevel + (bandLevel - pictureLevel) * 0.45 * t
                            + CGFloat(rng.next() - 0.5) * pictureSpread * (1 - t)
                    }
                    ctx.setFillColor(grey(v))
                    ctx.fill(cell)
                    x += CGFloat(block)
                }
                y += CGFloat(block)
            }
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.03,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - A single sheet

    func testFindsOneFrameSurroundedByUnexposedFilm() throws {
        let frame = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let img = try makeFilm(frames: [frame])
        let r = try XCTUnwrap(FrameFinder.detect(in: img))
        assertRect(r.rect, frame)
        XCTAssertTrue(r.isFullyBounded)
    }

    /// Reversal film: the unexposed band is *dense*, so it reads dark against a
    /// bright picture. Nothing may assume the band is the brighter side.
    func testFindsAFrameWhenTheUnexposedBandIsDark() throws {
        let frame = CGRect(x: 0.22, y: 0.25, width: 0.55, height: 0.50)
        let img = try makeFilm(frames: [frame], bandLevel: 0.06, pictureLevel: 0.62)
        let r = try XCTUnwrap(FrameFinder.detect(in: img))
        assertRect(r.rect, frame)
        XCTAssertTrue(r.isFullyBounded)
    }

    // MARK: - A strip

    /// The point of searching outwards from the centre: with three frames in
    /// view, a bounding box of "everything that isn't background" would span all
    /// three. Only the one under the lens is wanted.
    func testPicksTheMiddleFrameOfAStrip() throws {
        let frames = [
            CGRect(x: 0.02, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.36, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.70, y: 0.20, width: 0.28, height: 0.60),
        ]
        let img = try makeFilm(frames: frames)
        let r = try XCTUnwrap(FrameFinder.detect(in: img))
        assertRect(r.rect, frames[1])
    }

    /// The lens isn't always over the middle of the picture, so the starting
    /// point has to be able to move.
    func testStartingPointSelectsWhichFrameIsFound() throws {
        let frames = [
            CGRect(x: 0.02, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.36, y: 0.20, width: 0.28, height: 0.60),
            CGRect(x: 0.70, y: 0.20, width: 0.28, height: 0.60),
        ]
        let img = try makeFilm(frames: frames)
        let left = try XCTUnwrap(
            FrameFinder.detect(in: img, around: CGPoint(x: 0.16, y: 0.5)))
        assertRect(left.rect, frames[0])
        let right = try XCTUnwrap(
            FrameFinder.detect(in: img, around: CGPoint(x: 0.84, y: 0.5)))
        assertRect(right.rect, frames[2])
    }

    // MARK: - Running off the picture

    /// Framed too tightly, the film runs past what the camera can see. The crop
    /// is still useful, but it is no longer a measurement of the frame's size,
    /// and the caller has to be able to tell the difference.
    func testReportsSidesWhereTheFilmRunsOffThePicture() throws {
        // Left edge of the frame is outside the picture entirely.
        let frame = CGRect(x: -0.20, y: 0.20, width: 0.75, height: 0.60)
        let img = try makeFilm(frames: [frame])
        let r = try XCTUnwrap(FrameFinder.detect(in: img))
        XCTAssertEqual(r.unboundedEdges, [.left])
        XCTAssertFalse(r.isFullyBounded)
        XCTAssertEqual(r.rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(r.rect.maxX, 0.55, accuracy: 0.03)
    }

    /// A negative filling the whole picture has no edges to find. Returning the
    /// whole frame dressed up as a detection would be worse than admitting it —
    /// measured on a real capture where exactly this happens.
    func testRefusesWhenNoEdgeIsVisibleAtAll() throws {
        let img = try makeFilm(frames: [CGRect(x: -0.1, y: -0.1, width: 1.2, height: 1.2)])
        XCTAssertNil(FrameFinder.detect(in: img))
    }

    // MARK: - Not being fooled

    /// The failure a real negative produced: a smooth, bright region *inside*
    /// the photograph passed both the smoothness and the level test, and cut the
    /// frame short by an eighth of its height.
    ///
    /// What separates it from a real edge is that exposed and unexposed film
    /// meet at a step, while a featureless part of a picture blends into what
    /// surrounds it. Measured on that negative: 0.023 for the smooth patch
    /// against 0.17–0.39 for the three real edges.
    func testASmoothBrightRegionInsideThePictureIsNotAnEdge() throws {
        let frame = CGRect(x: 0.20, y: 0.15, width: 0.60, height: 0.70)
        let img = try makeFilm(frames: [frame], smoothPatch: 0.35)
        let r = try XCTUnwrap(FrameFinder.detect(in: img))
        // The top edge is the one under attack: it must still reach the film.
        XCTAssertEqual(r.rect.minY, frame.minY, accuracy: 0.04,
                       "stopped at the smooth patch instead of the frame's edge")
        assertRect(r.rect, frame, accuracy: 0.04)
    }

    /// A single stray smooth line — a scratch, an artefact — is not a boundary.
    func testASingleSmoothLineDoesNotEndTheFrame() throws {
        let frame = CGRect(x: 0.20, y: 0.15, width: 0.60, height: 0.70)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = try makeFilm(frames: [frame])
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.8, 0.8, 0.8, 1])!)
        // One scratch across the middle of the frame.
        ctx.fill(CGRect(x: 0.20 * CGFloat(width), y: CGFloat(height) * 0.45,
                        width: 0.60 * CGFloat(width), height: 2))
        let scratched = try XCTUnwrap(ctx.makeImage())
        let r = try XCTUnwrap(FrameFinder.detect(in: scratched))
        assertRect(r.rect, frame, accuracy: 0.04)
    }

    // MARK: - Margin

    func testMarginGrowsTheCropAndStaysInThePicture() throws {
        let frame = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let img = try makeFilm(frames: [frame])
        let tight = try XCTUnwrap(FrameFinder.detect(in: img))
        let loose = try XCTUnwrap(FrameFinder.detect(in: img, marginFraction: 0.02))
        XCTAssertGreaterThan(loose.rect.width, tight.rect.width)
        XCTAssertGreaterThan(loose.rect.height, tight.rect.height)
        XCTAssertGreaterThanOrEqual(loose.rect.minX, 0)
        XCTAssertGreaterThanOrEqual(loose.rect.minY, 0)
        XCTAssertLessThanOrEqual(loose.rect.maxX, 1)
        XCTAssertLessThanOrEqual(loose.rect.maxY, 1)
    }

    // MARK: - Reported film base

    /// The unexposed film's level is reported so a later stage can check the
    /// bands agree with each other, and so the film base colour is available for
    /// white balance without asking the operator to click it.
    func testReportsTheLevelOfTheUnexposedFilm() throws {
        let frame = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let img = try makeFilm(frames: [frame], bandLevel: 0.80)
        let r = try XCTUnwrap(FrameFinder.detect(in: img))
        let level = try XCTUnwrap(r.filmBaseLevel)
        XCTAssertEqual(level, 0.80, accuracy: 0.06)
    }
}
