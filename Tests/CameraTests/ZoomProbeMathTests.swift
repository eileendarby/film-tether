import XCTest
import CoreGraphics
import ImageIO
@testable import Camera

final class ZoomProbeMathTests: XCTestCase {

    /// Synthesize a solid-gray JPEG of `value` luminance, 200×200.
    private func gray(_ value: UInt8) -> Data {
        let size = 200
        let cs = CGColorSpaceCreateDeviceGray()
        var bytes = [UInt8](repeating: value, count: size * size)
        guard let ctx = CGContext(
            data: &bytes,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ),
        let img = ctx.makeImage() else {
            return Data()
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            return Data()
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testIdenticalFramesProduceZeroDiff() {
        let g = gray(128)
        let diff = LiveZoom.meanCenterPixelDifference(baseline: g, zoomed: g)
        // JPEG quantization can introduce tiny residuals even on identical frames; still < 1.
        XCTAssertLessThan(diff, 1.0)
    }

    func testDifferentFramesProduceLargeDiff() {
        let dark = gray(20)
        let bright = gray(220)
        let diff = LiveZoom.meanCenterPixelDifference(baseline: dark, zoomed: bright)
        // |220 - 20| = 200 in the limit; JPEG compression knocks it down but >> 8.
        XCTAssertGreaterThan(diff, 50.0)
    }

    func testJPEGCropDownsizesCenter() {
        let g = gray(128)
        guard let cropped = JPEGCrop.centerCrop(g, divisor: 5) else {
            XCTFail("crop returned nil")
            return
        }
        // Decode and check dimensions directly: a 1/5 crop of 200×200 is 40×40.
        // (An earlier byte-size assertion was flaky: a tiny JPEG's fixed
        // header/profile overhead can exceed a solid-gray source's total size.)
        XCTAssertGreaterThan(cropped.count, 0)
        guard let source = CGImageSourceCreateWithData(cropped as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            XCTFail("cropped JPEG failed to decode")
            return
        }
        XCTAssertEqual(img.width, 40)
        XCTAssertEqual(img.height, 40)
    }

    func testJPEGCropDivisor1ReturnsOriginal() {
        let g = gray(128)
        let unchanged = JPEGCrop.centerCrop(g, divisor: 1)
        XCTAssertEqual(unchanged, g)
    }
}
