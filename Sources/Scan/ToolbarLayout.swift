import Foundation
import CoreGraphics

/// Which layout the toolbar takes at a given width — decided by arithmetic
/// on measured piece widths, so the app renders one bar and never asks
/// SwiftUI to lay out two dozen candidates per frame.
///
/// The bar is a fixed part (pickers, focus menu) followed by *items* in bar
/// order: buttons that always keep their label (Capture, Live, Zoom,
/// Rotate) and toggles that can collapse to an icon. The sequence, widest
/// first, as the window narrows:
///
/// 1. One row. Toggles lose their labels from the **right** — the last
///    toggle first — until every toggle is an icon.
/// 2. A second row. Items drop to it from the **right**, one at a time —
///    the toggles first, then Rotate, Zoom, Live, Capture — and an item on
///    the second row is labelled.
/// 3. With everything on the second row, its toggles go compact from the
///    **left**, until all are icons. That is the minimum width: the wider
///    of the fixed part and the second row.
public enum ToolbarLayout: Equatable, Sendable {
    /// One row; the first `labelled` toggles carry labels.
    case row(labelled: Int)
    /// Two rows; the last `moved` items are on the second, its toggles
    /// labelled except for the first `compacted` of them.
    case wrapped(moved: Int, compacted: Int)

    /// One item's measurements.
    public struct Item: Equatable, Sendable {
        public var labelled: CGFloat
        /// Width as an icon; nil for an item that always keeps its label.
        public var compact: CGFloat?
        public init(labelled: CGFloat, compact: CGFloat?) {
            self.labelled = labelled
            self.compact = compact
        }
        public var canCompact: Bool { compact != nil }
    }

    /// What the pieces measure, in points.
    public struct Widths: Equatable, Sendable {
        /// Everything before the items: pickers, dividers, the focus menu —
        /// including the spacing between them.
        public var fixed: CGFloat
        /// The items in bar order.
        public var items: [Item]
        /// The gap between neighbours in a row.
        public var spacing: CGFloat

        public init(fixed: CGFloat, items: [Item], spacing: CGFloat) {
            self.fixed = fixed
            self.items = items
            self.spacing = spacing
        }

        public var count: Int { items.count }
        public var compactableCount: Int { items.filter(\.canCompact).count }
    }

    /// Which items can compact, in bar order — what `isLabelled` and the
    /// sequence are defined over.
    public static func isLabelled(_ layout: ToolbarLayout, item i: Int, compactable: [Bool]) -> Bool {
        let n = compactable.count
        guard i >= 0, i < n else { return true }
        guard compactable[i] else { return true }
        // Rank of this item among the compactable ones, counted from a start.
        func rank(from start: Int) -> Int {
            (start..<i).filter { compactable[$0] }.count
        }
        switch layout {
        case .row(let labelled):
            return rank(from: 0) < labelled
        case .wrapped(let moved, let compacted):
            let split = n - moved
            guard i >= split else { return false }
            return rank(from: split) >= compacted
        }
    }

    public func isLabelled(item i: Int, compactable: [Bool]) -> Bool {
        Self.isLabelled(self, item: i, compactable: compactable)
    }

    /// Every layout, widest first.
    public static func all(items n: Int, compactable c: Int) -> [ToolbarLayout] {
        guard n > 0 else { return [.row(labelled: 0)] }
        return (0...c).reversed().map { ToolbarLayout.row(labelled: $0) }
            + (1...n).map { ToolbarLayout.wrapped(moved: $0, compacted: 0) }
            + (c > 0 ? (1...c).map { ToolbarLayout.wrapped(moved: n, compacted: $0) } : [])
    }

    public static func narrowest(items n: Int, compactable c: Int) -> ToolbarLayout {
        n > 0 ? .wrapped(moved: n, compacted: c) : .row(labelled: 0)
    }

    /// The bar's width at this layout: the wider of its rows.
    public func width(_ w: Widths) -> CGFloat {
        let compactable = w.items.map(\.canCompact)
        func itemWidth(_ i: Int) -> CGFloat {
            let item = w.items[i]
            return isLabelled(item: i, compactable: compactable) ? item.labelled : (item.compact ?? item.labelled)
        }
        switch self {
        case .row:
            var total = w.fixed
            for i in 0..<w.count { total += w.spacing + itemWidth(i) }
            return total
        case .wrapped(let moved, _):
            let split = w.count - moved
            var row1 = w.fixed
            for i in 0..<split { row1 += w.spacing + itemWidth(i) }
            var row2: CGFloat = 0
            for i in split..<w.count { row2 += (i == split ? 0 : w.spacing) + itemWidth(i) }
            return max(row1, row2)
        }
    }

    /// The widest layout that fits, or the narrowest if none does.
    public static func choose(available: CGFloat, widths: Widths) -> ToolbarLayout {
        let candidates = all(items: widths.count, compactable: widths.compactableCount)
        return candidates.first { $0.width(widths) <= available }
            ?? narrowest(items: widths.count, compactable: widths.compactableCount)
    }
}
