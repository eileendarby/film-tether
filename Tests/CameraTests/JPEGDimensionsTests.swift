import XCTest
@testable import Camera

final class JPEGDimensionsTests: XCTestCase {

    /// Minimal synthetic JPEG: SOI + SOF0 with known dimensions + dummy quant table + EOI.
    private func syntheticJPEG(width: Int, height: Int) -> Data {
        var bytes: [UInt8] = []
        // SOI
        bytes += [0xFF, 0xD8]
        // SOF0 marker + segment
        // FF C0  (marker)
        // 00 11  (length = 17)
        // 08     (precision)
        // hh hh  (height)
        // ww ww  (width)
        // 03     (3 components)
        // 01 22 00  02 11 01  03 11 01  (component tables)
        bytes += [0xFF, 0xC0, 0x00, 0x11, 0x08]
        bytes += [UInt8((height >> 8) & 0xFF), UInt8(height & 0xFF)]
        bytes += [UInt8((width >> 8) & 0xFF), UInt8(width & 0xFF)]
        bytes += [0x03,
                  0x01, 0x22, 0x00,
                  0x02, 0x11, 0x01,
                  0x03, 0x11, 0x01]
        // EOI
        bytes += [0xFF, 0xD9]
        return Data(bytes)
    }

    func testParsesDimensions() {
        let jpeg = syntheticJPEG(width: 1024, height: 680)
        let (w, h) = LiveView.parseJPEGDimensions(jpeg)
        XCTAssertEqual(w, 1024)
        XCTAssertEqual(h, 680)
    }

    func testNonJPEGReturnsNil() {
        let bytes = Data([0x00, 0x01, 0x02, 0x03])
        let (w, h) = LiveView.parseJPEGDimensions(bytes)
        XCTAssertNil(w)
        XCTAssertNil(h)
    }

    func testEmptyDataReturnsNil() {
        let (w, h) = LiveView.parseJPEGDimensions(Data())
        XCTAssertNil(w)
        XCTAssertNil(h)
    }
}
