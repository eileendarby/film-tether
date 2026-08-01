import XCTest
import CoreGraphics
@testable import Scan

final class CropDetectorTests: XCTestCase {

    /// Frame with a single rectangle of `fg` on a field of `bg`, positioned by
    /// normalized top-down coordinates so the tests read like the picture.
    private func makeFrame(
        width: Int = 640, height: Int = 480,
        bg: CGFloat, fg: CGFloat, rect: CGRect,
        specks: [CGPoint] = []
    ) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        func grey(_ v: CGFloat) -> CGColor {
            CGColor(colorSpace: space, components: [v, v, v, 1])!
        }
        ctx.setFillColor(grey(bg))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(grey(fg))
        // Flip y: the context is y-up, the test's rect is y-down.
        ctx.fill(CGRect(
            x: rect.minX * CGFloat(width),
            y: (1 - rect.maxY) * CGFloat(height),
            width: rect.width * CGFloat(width),
            height: rect.height * CGFloat(height)
        ))
        for speck in specks {
            ctx.fill(CGRect(x: speck.x * CGFloat(width),
                            y: (1 - speck.y) * CGFloat(height),
                            width: 3, height: 3))
        }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.02,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - Core behaviour

    func testFindsABrightNegativeOnADarkMask() throws {
        let target = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
        let img = try makeFrame(bg: 0.05, fg: 0.80, rect: target)
        let result = try XCTUnwrap(CropDetector.detect(in: img))
        assertRect(result.rect, target)
    }

    /// The polarity that matters for film: a dense negative is *darker* than the
    /// light table behind it, so detection can't assume content is brighter.
    func testFindsADarkNegativeOnABrightLightTable() throws {
        let target = CGRect(x: 0.30, y: 0.15, width: 0.40, height: 0.70)
        let img = try makeFrame(bg: 0.95, fg: 0.30, rect: target)
        let result = try XCTUnwrap(CropDetector.detect(in: img))
        assertRect(result.rect, target)
    }

    func testFindsAnOffCentreNegative() throws {
        let target = CGRect(x: 0.05, y: 0.55, width: 0.35, height: 0.40)
        let img = try makeFrame(bg: 0.9, fg: 0.2, rect: target)
        let result = try XCTUnwrap(CropDetector.detect(in: img))
        assertRect(result.rect, target)
    }

    /// A dark, dense negative is the case Alex flagged as fooling auto-crop, so
    /// it gets an explicit test: only 12% separation from the background.
    func testFindsALowContrastDenseNegative() throws {
        let target = CGRect(x: 0.20, y: 0.20, width: 0.55, height: 0.55)
        let img = try makeFrame(bg: 0.30, fg: 0.18, rect: target)
        let result = try XCTUnwrap(CropDetector.detect(in: img))
        assertRect(result.rect, target, accuracy: 0.03)
    }

    // MARK: - Robustness

    /// Dust and scratches are the reason detection works on projection profiles
    /// rather than a plain bounding box of all differing pixels: a few specks
    /// scattered across the mask must not drag the crop out to the frame edges.
    func testDustSpecksDoNotEnlargeTheCrop() throws {
        let target = CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.40)
        let img = try makeFrame(
            bg: 0.9, fg: 0.2, rect: target,
            specks: [CGPoint(x: 0.02, y: 0.03), CGPoint(x: 0.95, y: 0.10),
                     CGPoint(x: 0.10, y: 0.92), CGPoint(x: 0.88, y: 0.85)]
        )
        let result = try XCTUnwrap(CropDetector.detect(in: img))
        assertRect(result.rect, target, accuracy: 0.03)
    }

    func testReturnsNilForAFeaturelessFrame() throws {
        let img = try makeFrame(bg: 0.5, fg: 0.5, rect: CGRect(x: 0, y: 0, width: 0, height: 0))
        XCTAssertNil(CropDetector.detect(in: img))
    }

    func testCoverageReportsHowMuchWasMarked() throws {
        let target = CGRect(x: 0.25, y: 0.25, width: 0.50, height: 0.50)
        let img = try makeFrame(bg: 0.9, fg: 0.1, rect: target)
        let result = try XCTUnwrap(CropDetector.detect(in: img))
        // A quarter of the frame, give or take resampling at the edges.
        XCTAssertEqual(result.coverage, 0.25, accuracy: 0.05)
    }

    // MARK: - Margin

    func testMarginGrowsTheCropOnEverySide() throws {
        let target = CGRect(x: 0.30, y: 0.30, width: 0.40, height: 0.40)
        let img = try makeFrame(bg: 0.9, fg: 0.2, rect: target)
        let tight = try XCTUnwrap(CropDetector.detect(in: img))
        let loose = try XCTUnwrap(CropDetector.detect(in: img, marginFraction: 0.05))
        XCTAssertEqual(loose.rect.minX, tight.rect.minX - 0.05, accuracy: 0.01)
        XCTAssertEqual(loose.rect.width, tight.rect.width + 0.10, accuracy: 0.01)
        XCTAssertEqual(loose.rect.height, tight.rect.height + 0.10, accuracy: 0.01)
    }

    /// Breathing room must not push the crop off the frame, or the stored corner
    /// positions would be outside the image they refer to.
    func testMarginIsClampedToTheFrame() throws {
        let target = CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96)
        let img = try makeFrame(bg: 0.9, fg: 0.2, rect: target)
        let result = try XCTUnwrap(CropDetector.detect(in: img, marginFraction: 0.10))
        XCTAssertGreaterThanOrEqual(result.rect.minX, 0)
        XCTAssertGreaterThanOrEqual(result.rect.minY, 0)
        XCTAssertLessThanOrEqual(result.rect.maxX, 1)
        XCTAssertLessThanOrEqual(result.rect.maxY, 1)
    }

    // MARK: - Roll film strips

    // MARK: - Feeding the size matcher

    /// End to end: detect a 35mm-shaped negative and have the catalogue
    /// recognise the shape.
    func testDetectedShapeFeedsTheFilmSizeMatcher() throws {
        // 3:2 in frame pixels: 0.60 x 0.40 of a 640x480 frame is 384x192 px...
        // deliberately sized so the detected rect is 3:2 in real pixels.
        let target = CGRect(x: 0.20, y: 0.20, width: 0.60, height: 0.53333)
        let img = try makeFrame(width: 640, height: 480, bg: 0.9, fg: 0.2, rect: target)
        let result = try XCTUnwrap(CropDetector.detect(in: img))
        let pixels = CGSize(width: result.rect.width * 640, height: result.rect.height * 480)
        let ids = Set(FilmSizeMatcher.candidates(forCropSize: pixels, in: FilmSize.seedCatalog)
            .map(\.size.id))
        XCTAssertTrue(ids.contains(4) || ids.contains(8),
                      "a 3:2 crop should offer 35mm and/or 6x9, got \(ids)")
    }
}
