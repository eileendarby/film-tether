import XCTest
import CoreGraphics
@testable import Scan

final class PreviewZoomTests: XCTestCase {

    func testCycleOrderIsFitThenActualThenFiveXAndWraps() {
        var z = PreviewZoom.fit
        z = z.next; XCTAssertEqual(z, .actual)
        z = z.next; XCTAssertEqual(z, .fiveX)
        z = z.next; XCTAssertEqual(z, .fit)
    }

    func testOnlyFiveXEngagesTheCameraPunchIn() {
        XCTAssertFalse(PreviewZoom.fit.engagesCameraPunchIn)
        XCTAssertFalse(PreviewZoom.actual.engagesCameraPunchIn)
        XCTAssertTrue(PreviewZoom.fiveX.engagesCameraPunchIn)
    }

    func testLabels() {
        XCTAssertEqual(PreviewZoom.fit.label(fitPercent: 85), "Fit (85%)")
        XCTAssertEqual(PreviewZoom.actual.label(fitPercent: 85), "100%")
        XCTAssertEqual(PreviewZoom.fiveX.label(fitPercent: 85), "500%")
    }

    /// Live view off means no frame to measure, so the label must degrade to a
    /// bare word rather than showing a bogus percentage.
    func testFitLabelOmitsPercentageWhenUnavailable() {
        XCTAssertEqual(PreviewZoom.fit.label(fitPercent: nil), "Fit")
    }

    func testFitPercentUsesTheMoreConstrainingAxis() {
        // 1056×704 frame in a pane that's wide but short: height constrains.
        let p = PreviewZoom.fitPercent(frame: CGSize(width: 1056, height: 704),
                                       pane: CGSize(width: 2000, height: 352))
        XCTAssertEqual(p, 50)
    }

    func testFitPercentCanExceedOneHundredWhenThePaneIsLarger() {
        let p = PreviewZoom.fitPercent(frame: CGSize(width: 100, height: 100),
                                       pane: CGSize(width: 250, height: 250))
        XCTAssertEqual(p, 250)
    }

    /// The rotation-recalculates-zoom requirement, expressed as arithmetic: the
    /// same frame in the same pane fits at a different percentage once its width
    /// and height are swapped.
    func testRotatingTheFrameChangesTheFitPercentage() {
        let pane = CGSize(width: 900, height: 600)
        let landscape = PreviewZoom.fitPercent(frame: CGSize(width: 1200, height: 800), pane: pane)
        let portrait = PreviewZoom.fitPercent(frame: CGSize(width: 800, height: 1200), pane: pane)
        XCTAssertEqual(landscape, 75)   // 900/1200 and 600/800 both = 0.75
        XCTAssertEqual(portrait, 50)    // 600/1200 constrains
        XCTAssertNotEqual(landscape, portrait)
    }

    func testFitPercentIsNilForDegenerateSizes() {
        let frame = CGSize(width: 100, height: 100)
        let pane = CGSize(width: 100, height: 100)
        XCTAssertNil(PreviewZoom.fitPercent(frame: .zero, pane: pane))
        XCTAssertNil(PreviewZoom.fitPercent(frame: frame, pane: .zero))
        XCTAssertNil(PreviewZoom.fitPercent(frame: CGSize(width: 100, height: 0), pane: pane))
        XCTAssertNil(PreviewZoom.fitPercent(frame: frame, pane: CGSize(width: 0, height: 100)))
    }
}
