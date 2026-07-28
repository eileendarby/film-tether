import XCTest
import CoreGraphics
@testable import Scan

final class PixelSamplerTests: XCTestCase {

    /// Four solid quadrants, so a sample's result tells us unambiguously which
    /// part of the image was read — this is what pins down the y-down,
    /// top-left-origin convention.
    ///   top-left red, top-right green, bottom-left blue, bottom-right white

    /// Build the colour in the *same* space the sampler reads through.
    /// `CGColor(red:green:blue:alpha:)` is not sRGB, so filling with it and
    /// reading back through sRGB converts and shifts every channel.
    static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(colorSpace: PixelSampler.workingSpace, components: [r, g, b, 1])!
    }

    private func makeQuadrantImage(side: Int = 64) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: PixelSampler.workingSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let h = CGFloat(side) / 2
        // CGContext is y-up, so the "top" quadrants are drawn at the high y.
        ctx.setFillColor(Self.srgb(1, 0, 0))
        ctx.fill(CGRect(x: 0, y: h, width: h, height: h))          // top-left
        ctx.setFillColor(Self.srgb(0, 1, 0))
        ctx.fill(CGRect(x: h, y: h, width: h, height: h))          // top-right
        ctx.setFillColor(Self.srgb(0, 0, 1))
        ctx.fill(CGRect(x: 0, y: 0, width: h, height: h))          // bottom-left
        ctx.setFillColor(Self.srgb(1, 1, 1))
        ctx.fill(CGRect(x: h, y: 0, width: h, height: h))          // bottom-right
        return try XCTUnwrap(ctx.makeImage())
    }

    private func assertColor(
        _ actual: (red: Double, green: Double, blue: Double)?,
        _ expected: (Double, Double, Double),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else { return XCTFail("no sample", file: file, line: line) }
        XCTAssertEqual(actual.red, expected.0, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual.green, expected.1, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.2, accuracy: 0.02, file: file, line: line)
    }

    func testSamplesTheQuadrantTheNormalizedPointNames() throws {
        let img = try makeQuadrantImage()
        assertColor(PixelSampler.averageColor(in: img, atNormalized: CGPoint(x: 0.25, y: 0.25)),
                    (1, 0, 0))     // top-left
        assertColor(PixelSampler.averageColor(in: img, atNormalized: CGPoint(x: 0.75, y: 0.25)),
                    (0, 1, 0))     // top-right
        assertColor(PixelSampler.averageColor(in: img, atNormalized: CGPoint(x: 0.25, y: 0.75)),
                    (0, 0, 1))     // bottom-left
        assertColor(PixelSampler.averageColor(in: img, atNormalized: CGPoint(x: 0.75, y: 0.75)),
                    (1, 1, 1))     // bottom-right
    }

    /// A click right on the edge must still return that corner's colour rather
    /// than running off the image or bleeding in a neighbouring quadrant.
    func testCornerClicksStayInsideTheImage() throws {
        let img = try makeQuadrantImage()
        assertColor(PixelSampler.averageColor(in: img, atNormalized: CGPoint(x: 0, y: 0)),
                    (1, 0, 0))
        assertColor(PixelSampler.averageColor(in: img, atNormalized: CGPoint(x: 1, y: 1)),
                    (1, 1, 1))
    }

    func testAveragesAcrossThePatchRatherThanReadingOnePixel() throws {
        // Half red, half black, split down the middle. A patch centred on the
        // seam must come back at roughly half red, which a single-pixel read
        // could never produce.
        let side = 64
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: PixelSampler.workingSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(Self.srgb(0, 0, 0))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(Self.srgb(1, 0, 0))
        ctx.fill(CGRect(x: 0, y: 0, width: side / 2, height: side))
        let img = try XCTUnwrap(ctx.makeImage())

        let s = try XCTUnwrap(PixelSampler.averageColor(
            in: img, atNormalized: CGPoint(x: 0.5, y: 0.5), patchSize: 8
        ))
        XCTAssertEqual(s.red, 0.5, accuracy: 0.1)
        XCTAssertEqual(s.green, 0, accuracy: 0.02)
    }

    func testPatchLargerThanTheImageIsClampedRatherThanFailing() throws {
        let img = try makeQuadrantImage(side: 4)
        XCTAssertNotNil(PixelSampler.averageColor(
            in: img, atNormalized: CGPoint(x: 0.5, y: 0.5), patchSize: 999
        ))
    }

    func testNonPositivePatchSizeIsRefused() throws {
        let img = try makeQuadrantImage()
        XCTAssertNil(PixelSampler.averageColor(
            in: img, atNormalized: CGPoint(x: 0.5, y: 0.5), patchSize: 0
        ))
    }

    /// End to end: sampling a cast and neutralising it should return grey.
    func testSampledCastFeedsGainsThatNeutraliseIt() throws {
        let side = 32
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: PixelSampler.workingSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(Self.srgb(0.9, 0.5, 0.2))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let img = try XCTUnwrap(ctx.makeImage())

        let s = try XCTUnwrap(PixelSampler.averageColor(
            in: img, atNormalized: CGPoint(x: 0.5, y: 0.5)
        ))
        let g = try XCTUnwrap(ChannelGains.neutralizing(red: s.red, green: s.green, blue: s.blue))
        let corrected = (s.red * g.red, s.green * g.green, s.blue * g.blue)
        XCTAssertEqual(corrected.0, corrected.1, accuracy: 1e-6)
        XCTAssertEqual(corrected.1, corrected.2, accuracy: 1e-6)
    }
}
