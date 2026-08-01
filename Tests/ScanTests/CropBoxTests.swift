import XCTest
import CoreGraphics
@testable import Scan

final class CropBoxTests: XCTestCase {

    private let box = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
    private let tol = CGSize(width: 0.03, height: 0.03)

    private func assertRect(
        _ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 1e-9,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height", file: file, line: line)
    }

    // MARK: - Hit testing

    func testEachGripIsFoundAtItsOwnCorner() {
        for (handle, p) in CropBox.handlePositions(in: box) {
            XCTAssertEqual(CropBox.handle(at: p, in: box, tolerance: tol), handle,
                           "\(handle.rawValue) not found at its own position")
        }
    }

    func testInsideTheBoxMovesIt() {
        XCTAssertEqual(CropBox.handle(at: CGPoint(x: 0.5, y: 0.5), in: box, tolerance: tol),
                       .interior)
    }

    func testOutsideTheBoxIsNothing() {
        XCTAssertNil(CropBox.handle(at: CGPoint(x: 0.05, y: 0.05), in: box, tolerance: tol))
    }

    /// Corner and edge targets overlap. A click in the overlap almost always
    /// means the corner — it's the more precise thing to have aimed at, and the
    /// harder one to hit by accident.
    func testACornerWinsOverAnEdgeWhereTheirTargetsOverlap() {
        // Just inside the top-left corner, still within the top edge's reach
        // because the box is wide enough for the two to overlap there.
        let near = CGPoint(x: box.minX + 0.005, y: box.minY + 0.005)
        XCTAssertEqual(CropBox.handle(at: near, in: box, tolerance: tol), .topLeft)
    }

    // MARK: - Resizing

    func testACornerMovesBothItsSides() {
        let r = CropBox.dragged(box, handle: .topLeft, by: CGSize(width: 0.05, height: 0.05))
        assertRect(r, CGRect(x: 0.30, y: 0.25, width: 0.45, height: 0.55))
    }

    func testAnEdgeMovesOnlyItsOwnSide() {
        let r = CropBox.dragged(box, handle: .right, by: CGSize(width: -0.10, height: 0.20))
        assertRect(r, CGRect(x: 0.25, y: 0.20, width: 0.40, height: 0.60),
                   accuracy: 1e-9)
    }

    func testMovingKeepsTheSize() {
        let r = CropBox.dragged(box, handle: .interior, by: CGSize(width: 0.10, height: -0.05))
        XCTAssertEqual(r.width, box.width, accuracy: 1e-9)
        XCTAssertEqual(r.height, box.height, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 0.35, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 0.15, accuracy: 1e-9)
    }

    // MARK: - Staying sane

    /// Dragging a side past its opposite must stop, not turn the box inside out.
    /// An inverted rect has a negative width, and every consumer downstream
    /// would have to defend against it separately.
    func testASideDraggedPastItsOppositeStops() {
        let r = CropBox.dragged(box, handle: .left, by: CGSize(width: 0.9, height: 0))
        XCTAssertGreaterThanOrEqual(r.width, CropBox.minSize)
        XCTAssertEqual(r.width, CropBox.minSize, accuracy: 1e-9)
        XCTAssertEqual(r.maxX, box.maxX, accuracy: 1e-9, "the opposite side moved")
    }

    func testACornerDraggedPastTheOppositeCornerStops() {
        let r = CropBox.dragged(box, handle: .bottomRight,
                                by: CGSize(width: -0.9, height: -0.9))
        XCTAssertEqual(r.width, CropBox.minSize, accuracy: 1e-9)
        XCTAssertEqual(r.height, CropBox.minSize, accuracy: 1e-9)
        XCTAssertEqual(r.minX, box.minX, accuracy: 1e-9)
        XCTAssertEqual(r.minY, box.minY, accuracy: 1e-9)
    }

    func testResizingStaysInsideTheFrame() {
        let r = CropBox.dragged(box, handle: .topLeft, by: CGSize(width: -0.9, height: -0.9))
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 0, accuracy: 1e-9)
    }

    func testMovingStopsAtTheFramesEdge() {
        let r = CropBox.dragged(box, handle: .interior, by: CGSize(width: 0.9, height: 0.9))
        XCTAssertEqual(r.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, 1, accuracy: 1e-9)
        XCTAssertEqual(r.width, box.width, accuracy: 1e-9)
    }

    func testSanitisingBringsADetectedRectIntoRange() {
        let r = CropBox.sanitised(CGRect(x: -0.2, y: 0.9, width: 0.001, height: 0.5))
        XCTAssertGreaterThanOrEqual(r.minX, 0)
        XCTAssertGreaterThanOrEqual(r.minY, 0)
        XCTAssertLessThanOrEqual(r.maxX, 1.0000001)
        XCTAssertLessThanOrEqual(r.maxY, 1.0000001)
        XCTAssertGreaterThanOrEqual(r.width, CropBox.minSize)
    }

    func testNudgingMovesByWholePixels() {
        let frame = CGSize(width: 1000, height: 500)
        let r = CropBox.nudged(box, handle: .right, byPixels: CGVector(dx: 10, dy: 0), in: frame)
        XCTAssertEqual((r.maxX - box.maxX) * frame.width, 10, accuracy: 1e-6)
    }

    // MARK: - Rotation

    /// The editor works in the rotated view; the crop is stored unrotated. A
    /// round trip must land exactly where it started, or the box would creep
    /// every time the preview is turned.
    func testRotationRoundTripsExactly() {
        for rotation in PreviewRotation.allCases {
            let display = rotation.displayRect(fromSensor: box)
            let back = rotation.sensorRect(fromDisplay: display)
            assertRect(back, box, accuracy: 1e-9)
        }
    }

    /// A quarter turn swaps the axes, which is the whole reason the editor can't
    /// work in sensor space directly.
    func testAQuarterTurnSwapsTheBoxesAxes() {
        let wide = CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)
        let turned = PreviewRotation.cw90.displayRect(fromSensor: wide)
        XCTAssertEqual(turned.width, wide.height, accuracy: 1e-9)
        XCTAssertEqual(turned.height, wide.width, accuracy: 1e-9)
    }

    func testNoRotationIsTheIdentity() {
        assertRect(PreviewRotation.none.displayRect(fromSensor: box), box)
    }
}

// MARK: - Zones

extension CropBoxTests {

    private var band: CGSize { CGSize(width: 0.04, height: 0.04) }

    func testAGripIsAResizeZone() {
        for (handle, p) in CropBox.handlePositions(in: box) {
            XCTAssertEqual(CropBox.zone(at: p, in: box, tolerance: tol, rotateBand: band),
                           .resize(handle), "\(handle.rawValue)")
        }
    }

    /// The rotate band sits *outside* each grip, so the two never compete for
    /// the same pixel — aiming at the box resizes, aiming just past it
    /// straightens.
    func testJustOutsideACornerIsARotateZone() {
        let outside = CGPoint(x: box.minX - tol.width - 0.01,
                              y: box.minY - tol.height - 0.01)
        XCTAssertEqual(CropBox.zone(at: outside, in: box, tolerance: tol, rotateBand: band),
                       .rotate(.topLeft))
    }

    func testJustOutsideAnEdgeHandleIsARotateZone() {
        let outside = CGPoint(x: box.midX, y: box.maxY + tol.height + 0.01)
        XCTAssertEqual(CropBox.zone(at: outside, in: box, tolerance: tol, rotateBand: band),
                       .rotate(.bottom))
    }

    /// Inside the box, a point that missed every grip moves the box. It must not
    /// become a rotate however close it is to an edge.
    func testInsideTheBoxIsNeverARotateZone() {
        let inside = CGPoint(x: box.minX + tol.width + 0.005, y: box.midY)
        XCTAssertEqual(CropBox.zone(at: inside, in: box, tolerance: tol, rotateBand: band), .move)
    }

    func testWellAwayFromTheBoxIsNothing() {
        XCTAssertEqual(CropBox.zone(at: CGPoint(x: 0.02, y: 0.02),
                                    in: box, tolerance: tol, rotateBand: band), .none)
    }

    // MARK: - Straightening angle

    /// Straight up from the centre is zero, and the angle runs clockwise.
    func testAngleIsMeasuredClockwiseFromUp() {
        let c = CGPoint(x: 0.5, y: 0.5)
        XCTAssertEqual(CropBox.angle(of: CGPoint(x: 0.5, y: 0.2), about: c, aspect: 1),
                       0, accuracy: 1e-6)
        XCTAssertEqual(CropBox.angle(of: CGPoint(x: 0.8, y: 0.5), about: c, aspect: 1),
                       90, accuracy: 1e-6)
        XCTAssertEqual(CropBox.angle(of: CGPoint(x: 0.5, y: 0.8), about: c, aspect: 1),
                       180, accuracy: 1e-6)
    }

    /// The pane is wider than it is tall, and normalized coordinates stretch x
    /// to match. Without undoing that, a straightening drag runs fast on one
    /// axis and slow on the other and stops tracking the pointer.
    func testAngleCorrectsForThePanesAspect() {
        let c = CGPoint(x: 0.5, y: 0.5)
        // A point on the diagonal of a 2:1 pane is at 45° on screen, but its
        // normalized offsets are not equal.
        let p = CGPoint(x: 0.5 + 0.1, y: 0.5 - 0.2)
        XCTAssertEqual(CropBox.angle(of: p, about: c, aspect: 2), 45, accuracy: 1e-6)
    }
}

// MARK: - Slack

extension CropBoxTests {

    func testExpandingGrowsEvenlyOnAllSides() {
        let r = CropBox.expanded(box, byFraction: 0.10)
        XCTAssertEqual(r.width, box.width * 1.10, accuracy: 1e-9)
        XCTAssertEqual(r.height, box.height * 1.10, accuracy: 1e-9)
        XCTAssertEqual(r.midX, box.midX, accuracy: 1e-9, "grew off-centre")
        XCTAssertEqual(r.midY, box.midY, accuracy: 1e-9, "grew off-centre")
    }

    /// The slack is a fraction of the box, not of the frame, so it stays
    /// proportional whether the negative is 35mm or 8x10.
    func testSlackIsProportionalToTheBox() {
        let small = CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)
        let big = CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90)
        XCTAssertEqual(CropBox.expanded(small, byFraction: 0.1).width / small.width,
                       CropBox.expanded(big, byFraction: 0.1).width / big.width,
                       accuracy: 1e-9)
    }

    func testExpandingStopsAtTheFrame() {
        let r = CropBox.expanded(CGRect(x: 0, y: 0, width: 1, height: 1), byFraction: 0.5)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(r.maxY, 1, accuracy: 1e-9)
    }

    func testExpandingByNothingChangesNothing() {
        assertRect(CropBox.expanded(box, byFraction: 0), box)
    }
}
