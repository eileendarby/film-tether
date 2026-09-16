import XCTest
@testable import Scan

final class ToolbarLayoutTests: XCTestCase {
    /// Fixed part 300; one always-labelled button of 80; three toggles
    /// 100 labelled / 30 compact; 10 between.
    private let w = ToolbarLayout.Widths(
        fixed: 300,
        items: [.init(labelled: 80, compact: nil),
                .init(labelled: 100, compact: 30), .init(labelled: 100, compact: 30), .init(labelled: 100, compact: 30)],
        spacing: 10
    )
    private let compactable = [false, true, true, true]

    func testOrderIsTheSpecifiedSequence() {
        XCTAssertEqual(ToolbarLayout.all(items: 4, compactable: 3), [
            .row(labelled: 3), .row(labelled: 2), .row(labelled: 1), .row(labelled: 0),
            .wrapped(moved: 1, compacted: 0), .wrapped(moved: 2, compacted: 0),
            .wrapped(moved: 3, compacted: 0), .wrapped(moved: 4, compacted: 0),
            .wrapped(moved: 4, compacted: 1), .wrapped(moved: 4, compacted: 2), .wrapped(moved: 4, compacted: 3),
        ])
    }

    func testWidths() {
        XCTAssertEqual(ToolbarLayout.row(labelled: 3).width(w), 300 + 90 + 3 * 110)
        XCTAssertEqual(ToolbarLayout.row(labelled: 0).width(w), 300 + 90 + 3 * 40)
        // One toggle moved: row 1 is fixed + button + two icons; row 2 one label.
        XCTAssertEqual(ToolbarLayout.wrapped(moved: 1, compacted: 0).width(w), 300 + 90 + 2 * 40)
        // Everything moved and labelled: row 2 is 80 + 10 + 3 × 100 + 2 × 10 = 410.
        XCTAssertEqual(ToolbarLayout.wrapped(moved: 4, compacted: 0).width(w), 410)
        // Then compacting from the left: 80 + 10 + 30 + 10 + 100 + 10 + 100 = 340.
        XCTAssertEqual(ToolbarLayout.wrapped(moved: 4, compacted: 1).width(w), 340)
        // All compact: 80 + 3 × 40 = 200 — but the fixed part is 300, the wider row.
        XCTAssertEqual(ToolbarLayout.wrapped(moved: 4, compacted: 3).width(w), 300)
    }

    func testTheAlwaysLabelledButtonKeepsItsLabelEverywhere() {
        for layout in ToolbarLayout.all(items: 4, compactable: 3) {
            XCTAssertTrue(layout.isLabelled(item: 0, compactable: compactable), "\(layout)")
        }
    }

    func testLabelsGoFromTheRight() {
        let two = ToolbarLayout.choose(available: 300 + 90 + 110 + 110 + 40, widths: w)
        XCTAssertEqual(two, .row(labelled: 2))
        XCTAssertTrue(two.isLabelled(item: 1, compactable: compactable))
        XCTAssertFalse(two.isLabelled(item: 3, compactable: compactable), "the rightmost toggle went compact first")
    }

    func testItemsDropToTheSecondRowFromTheRightAndAreLabelledThere() {
        // Narrower than the all-icons row (510): one toggle drops.
        let one = ToolbarLayout.choose(available: 470, widths: w)
        XCTAssertEqual(one, .wrapped(moved: 1, compacted: 0))
        XCTAssertTrue(one.isLabelled(item: 3, compactable: compactable), "labelled once on the second row")
        XCTAssertFalse(one.isLabelled(item: 2, compactable: compactable), "still an icon on the first row")
        // Narrower still: all three toggles down, then the button follows.
        XCTAssertEqual(ToolbarLayout.choose(available: 390, widths: w), .wrapped(moved: 3, compacted: 0))
        XCTAssertEqual(ToolbarLayout.wrapped(moved: 3, compacted: 0).width(w), 390, "row 1: 300 + 10 + 80")
        XCTAssertEqual(ToolbarLayout.choose(available: 380, widths: w), .wrapped(moved: 4, compacted: 1),
                       "the button drops (row 2 becomes 410, too wide) so the leftmost toggle compacts: 340")
    }

    func testSecondRowCompactsFromTheLeftDownToTheMinimum() {
        let l = ToolbarLayout.choose(available: 335, widths: w)
        XCTAssertEqual(l, .wrapped(moved: 4, compacted: 2))
        XCTAssertFalse(l.isLabelled(item: 1, compactable: compactable))
        XCTAssertFalse(l.isLabelled(item: 2, compactable: compactable))
        XCTAssertTrue(l.isLabelled(item: 3, compactable: compactable), "the rightmost keeps its label longest")
        XCTAssertEqual(ToolbarLayout.choose(available: 10, widths: w), .wrapped(moved: 4, compacted: 3), "nothing fits: the narrowest")
        XCTAssertEqual(ToolbarLayout.narrowest(items: 4, compactable: 3).width(w), 300, "the minimum is the fixed part here")
    }
}
