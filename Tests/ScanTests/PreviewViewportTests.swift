import XCTest
import CoreGraphics
@testable import Scan

final class PreviewViewportTests: XCTestCase {

    private let frame = CGSize(width: 1000, height: 600)

    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 1e-6,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - Visible window

    /// A pane covering half the frame's width and half its height at 1:1 shows a
    /// centred quarter of the frame.
    func testWindowIsPaneSizedAtOneToOne() {
        let rect = PreviewViewport.visibleRect(
            frame: frame, pane: CGSize(width: 500, height: 300),
            scale: 1, center: CGPoint(x: 0.5, y: 0.5)
        )
        assertRect(rect, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    /// The window takes the **pane's** shape, not the frame's — that's the whole
    /// point of filling the window when zoomed.
    func testWindowTakesThePanesAspectNotTheFrames() {
        // Square pane over a 5:3 frame.
        let rect = PreviewViewport.visibleRect(
            frame: frame, pane: CGSize(width: 300, height: 300),
            scale: 1, center: CGPoint(x: 0.5, y: 0.5)
        )
        // 300/1000 wide, 300/600 tall — deliberately different fractions.
        XCTAssertEqual(rect.width, 0.3, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 0.5, accuracy: 1e-6)
    }

    func testHigherScaleShowsLessOfTheFrame() {
        let pane = CGSize(width: 500, height: 300)
        let atOne = PreviewViewport.visibleRect(
            frame: frame, pane: pane, scale: 1, center: CGPoint(x: 0.5, y: 0.5))
        let atFive = PreviewViewport.visibleRect(
            frame: frame, pane: pane, scale: 5, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(atFive.width, atOne.width / 5, accuracy: 1e-6)
        XCTAssertEqual(atFive.height, atOne.height / 5, accuracy: 1e-6)
    }

    /// A pane bigger than the frame at this scale must show the whole frame,
    /// not a window hanging off the edge.
    func testWindowNeverExceedsTheFrame() {
        let rect = PreviewViewport.visibleRect(
            frame: frame, pane: CGSize(width: 4000, height: 4000),
            scale: 1, center: CGPoint(x: 0.5, y: 0.5)
        )
        assertRect(rect, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testDegenerateInputsFallBackToTheWholeFrame() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let c = CGPoint(x: 0.5, y: 0.5)
        assertRect(PreviewViewport.visibleRect(frame: .zero, pane: frame, scale: 1, center: c), full)
        assertRect(PreviewViewport.visibleRect(frame: frame, pane: .zero, scale: 1, center: c), full)
        assertRect(PreviewViewport.visibleRect(frame: frame, pane: frame, scale: 0, center: c), full)
    }

    // MARK: - Clamping

    /// Panning to a corner must stop at the frame's edge rather than showing
    /// empty space beyond it.
    func testWindowStaysInsideTheFrameWhenPannedToACorner() {
        let pane = CGSize(width: 500, height: 300)
        let topLeft = PreviewViewport.visibleRect(
            frame: frame, pane: pane, scale: 1, center: CGPoint(x: 0, y: 0))
        assertRect(topLeft, CGRect(x: 0, y: 0, width: 0.5, height: 0.5))

        let bottomRight = PreviewViewport.visibleRect(
            frame: frame, pane: pane, scale: 1, center: CGPoint(x: 1, y: 1))
        assertRect(bottomRight, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    /// An axis with nothing to pan along is pinned centred, so a fully-visible
    /// axis can't be dragged off to one side.
    func testFullyVisibleAxisIsPinnedToTheMiddle() {
        let c = PreviewViewport.clampCenter(
            CGPoint(x: 0.9, y: 0.1),
            visibleSize: CGSize(width: 1, height: 0.4)
        )
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.2, accuracy: 1e-9)
    }

    func testPannableOnlyWhenSomethingIsOffScreen() {
        XCTAssertFalse(PreviewViewport.isPannable(visibleSize: CGSize(width: 1, height: 1)))
        XCTAssertTrue(PreviewViewport.isPannable(visibleSize: CGSize(width: 0.5, height: 1)))
        XCTAssertTrue(PreviewViewport.isPannable(visibleSize: CGSize(width: 1, height: 0.5)))
    }

    // MARK: - Scroll to pan

    /// Scrolling follows the scroll-view convention: a positive delta pushes the
    /// content down and right, which means moving *towards* the top-left of the
    /// frame.
    func testScrollingDownMovesFurtherDownTheFrame() {
        let pane = CGSize(width: 500, height: 300)
        let visible = CGSize(width: 0.5, height: 0.5)
        let start = CGPoint(x: 0.5, y: 0.5)

        let up = PreviewViewport.pannedCenter(
            start, byScroll: CGSize(width: 0, height: 30),
            visibleSize: visible, pane: pane)
        XCTAssertLessThan(up.y, start.y)

        let down = PreviewViewport.pannedCenter(
            start, byScroll: CGSize(width: 0, height: -30),
            visibleSize: visible, pane: pane)
        XCTAssertGreaterThan(down.y, start.y)
        XCTAssertEqual(up.x, start.x, accuracy: 1e-9, "a vertical scroll must not drift sideways")
    }

    /// The image should travel as far as the gesture did — scrolling half the
    /// pane's height moves the window half its own height.
    func testScrollMovesTheImageByTheDistanceScrolled() {
        let pane = CGSize(width: 500, height: 300)
        let visible = CGSize(width: 0.5, height: 0.5)
        let moved = PreviewViewport.pannedCenter(
            CGPoint(x: 0.5, y: 0.5), byScroll: CGSize(width: 0, height: -150),
            visibleSize: visible, pane: pane)
        // Half a pane = half the visible fraction = 0.25 of the frame.
        XCTAssertEqual(moved.y, 0.75, accuracy: 1e-9)
    }

    /// Zoomed further in, the same gesture must cover less of the frame, or
    /// scrolling at 500% would fly across the negative.
    func testScrollCoversLessOfTheFrameWhenZoomedFurtherIn() {
        let pane = CGSize(width: 500, height: 300)
        let scroll = CGSize(width: 0, height: -30)
        let shallow = PreviewViewport.pannedCenter(
            CGPoint(x: 0.5, y: 0.5), byScroll: scroll,
            visibleSize: CGSize(width: 0.5, height: 0.5), pane: pane)
        let deep = PreviewViewport.pannedCenter(
            CGPoint(x: 0.5, y: 0.5), byScroll: scroll,
            visibleSize: CGSize(width: 0.1, height: 0.1), pane: pane)
        XCTAssertLessThan(deep.y - 0.5, shallow.y - 0.5)
    }

    func testScrollStopsAtTheFrameEdge() {
        let moved = PreviewViewport.pannedCenter(
            CGPoint(x: 0.5, y: 0.5), byScroll: CGSize(width: 0, height: -100_000),
            visibleSize: CGSize(width: 0.5, height: 0.5),
            pane: CGSize(width: 500, height: 300))
        XCTAssertEqual(moved.y, 0.75, accuracy: 1e-9)
    }

    func testScrollWithNoPaneIsSafe() {
        let c = PreviewViewport.pannedCenter(
            CGPoint(x: 0.9, y: 0.9), byScroll: CGSize(width: 10, height: 10),
            visibleSize: CGSize(width: 0.5, height: 0.5), pane: .zero)
        XCTAssertEqual(c.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.75, accuracy: 1e-9)
    }

    // MARK: - Navigator

    func testThumbnailKeepsFrameAspectWithinItsBudget() {
        // 3:2 frame in a square budget — width-limited.
        let s = PreviewViewport.thumbnailSize(
            frameAspect: 1.5, maxSize: CGSize(width: 180, height: 180))
        XCTAssertEqual(s.width, 180, accuracy: 1e-6)
        XCTAssertEqual(s.height, 120, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(s.height, 180)

        // 2:3 (rotated) frame — now height-limited.
        let tall = PreviewViewport.thumbnailSize(
            frameAspect: 2.0 / 3.0, maxSize: CGSize(width: 180, height: 180))
        XCTAssertEqual(tall.height, 180, accuracy: 1e-6)
        XCTAssertEqual(tall.width, 120, accuracy: 1e-6)
    }

    /// Dragging in the navigator moves the window to the pointer, and the same
    /// clamping applies so the indicator can't be dragged out of the thumbnail.
    func testNavigatorDragMapsToAClampedPanCentre() {
        let thumb = CGSize(width: 200, height: 120)
        let visible = CGSize(width: 0.5, height: 0.5)

        let middle = PreviewViewport.panCenter(
            forNavigatorPoint: CGPoint(x: 100, y: 60),
            thumbnailSize: thumb, visibleSize: visible)
        XCTAssertEqual(middle.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(middle.y, 0.5, accuracy: 1e-9)

        // Dragged past the top-left corner: clamps to the nearest legal centre.
        let corner = PreviewViewport.panCenter(
            forNavigatorPoint: CGPoint(x: -50, y: -50),
            thumbnailSize: thumb, visibleSize: visible)
        XCTAssertEqual(corner.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 0.25, accuracy: 1e-9)
    }

    func testNavigatorDragWithDegenerateThumbnailIsSafe() {
        let c = PreviewViewport.panCenter(
            forNavigatorPoint: CGPoint(x: 10, y: 10),
            thumbnailSize: .zero, visibleSize: CGSize(width: 0.5, height: 0.5))
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
    }

    /// Round trip: the centre the navigator reports must be the centre the
    /// visible window ends up at, or the indicator would lie about what's shown.
    func testNavigatorCentreAgreesWithTheVisibleWindow() {
        let pane = CGSize(width: 500, height: 300)
        let visible = CGSize(width: 0.5, height: 0.5)
        let thumb = CGSize(width: 200, height: 120)
        let c = PreviewViewport.panCenter(
            forNavigatorPoint: CGPoint(x: 150, y: 30),
            thumbnailSize: thumb, visibleSize: visible)
        let rect = PreviewViewport.visibleRect(
            frame: frame, pane: pane, scale: 1, center: c)
        XCTAssertEqual(rect.midX, c.x, accuracy: 1e-6)
        XCTAssertEqual(rect.midY, c.y, accuracy: 1e-6)
    }
}

// MARK: - Fitting the picture in the pane

extension PreviewViewportTests {

    /// A pane wider than the picture letterboxes left and right, and the
    /// picture is centred in what's left.
    func testAWidePaneLetterboxesSideways() {
        let r = PreviewViewport.fittedRect(aspect: 1.5, in: CGSize(width: 1000, height: 500))
        XCTAssertEqual(r.height, 500, accuracy: 1e-6)
        XCTAssertEqual(r.width, 750, accuracy: 1e-6)
        XCTAssertEqual(r.minX, 125, accuracy: 1e-6)
        XCTAssertEqual(r.minY, 0, accuracy: 1e-6)
    }

    func testATallPaneLetterboxesAboveAndBelow() {
        let r = PreviewViewport.fittedRect(aspect: 1.5, in: CGSize(width: 600, height: 800))
        XCTAssertEqual(r.width, 600, accuracy: 1e-6)
        XCTAssertEqual(r.height, 400, accuracy: 1e-6)
        XCTAssertEqual(r.minY, 200, accuracy: 1e-6)
    }

    /// The letterbox is the room the crop box's rotate handles reach into, so a
    /// pane that exactly matches the picture leaves none — worth pinning, since
    /// it's the case where those handles are hardest to reach.
    func testAMatchingPaneLeavesNoLetterbox() {
        let r = PreviewViewport.fittedRect(aspect: 2, in: CGSize(width: 800, height: 400))
        assertRect(r, CGRect(x: 0, y: 0, width: 800, height: 400), accuracy: 1e-6)
    }

    func testDegenerateFitFallsBackToTheWholePane() {
        let pane = CGSize(width: 300, height: 200)
        assertRect(PreviewViewport.fittedRect(aspect: 0, in: pane),
                   CGRect(origin: .zero, size: pane), accuracy: 1e-6)
    }
}
