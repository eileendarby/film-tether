import Foundation
import CoreGraphics

/// An adjustable crop rectangle: which handle a click lands on, and what
/// dragging it does.
///
/// Kept apart from the view because it's arithmetic, and arithmetic about
/// corners is where crop editors go wrong in ways that are tedious to find by
/// hand — dragging a corner past its opposite, an edge escaping the frame, a
/// box collapsing to nothing and becoming impossible to grab again. Those are
/// cheap to pin down here and expensive to chase in a live preview.
///
/// Everything is normalized [0,1]², y-down, in the space the box is *displayed*
/// in. The caller converts to and from sensor space around the edit, so the
/// rotation never has to be reasoned about here.
public enum CropBox {

    /// The eight grips, plus the inside of the box for moving it whole.
    public enum Handle: String, CaseIterable, Sendable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
        case interior

        /// Which sides this grip moves.
        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// Smallest the box may become, normalized. Small enough not to get in the
    /// way, large enough that its handles never overlap so far that it can't be
    /// grabbed and pulled open again.
    public static let minSize = 0.03

    /// Where each grip sits.
    public static func handlePositions(in rect: CGRect) -> [(Handle, CGPoint)] {
        [
            (.topLeft,     CGPoint(x: rect.minX, y: rect.minY)),
            (.top,         CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight,    CGPoint(x: rect.maxX, y: rect.minY)),
            (.left,        CGPoint(x: rect.minX, y: rect.midY)),
            (.right,       CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomLeft,  CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottom,      CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
        ]
    }

    /// Which grip `point` is on, or `.interior` inside the box, or nil outside.
    ///
    /// `tolerance` is the grab radius on each axis, normalized — the caller
    /// derives it from the pane's size so the target stays the same number of
    /// points however the window is scaled.
    ///
    /// Corners are tested before edges: their targets overlap, and a click in
    /// the overlap almost always means the corner, which is the more precise
    /// thing to have aimed at.
    public static func handle(
        at point: CGPoint, in rect: CGRect, tolerance: CGSize
    ) -> Handle? {
        let corners: [Handle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let positions = handlePositions(in: rect)
        for handle in corners {
            guard let p = positions.first(where: { $0.0 == handle })?.1 else { continue }
            if abs(point.x - p.x) <= tolerance.width, abs(point.y - p.y) <= tolerance.height {
                return handle
            }
        }
        for (handle, p) in positions where !corners.contains(handle) {
            if abs(point.x - p.x) <= tolerance.width, abs(point.y - p.y) <= tolerance.height {
                return handle
            }
        }
        return rect.insetBy(dx: -tolerance.width, dy: -tolerance.height).contains(point)
            ? .interior : nil
    }

    /// What the pointer is over, and so what a drag from here would do.
    public enum Zone: Equatable, Sendable {
        /// On a grip: drag resizes.
        case resize(Handle)
        /// Just outside a grip: drag straightens the picture underneath.
        /// The handle says which grip it belongs to, for choosing the cursor.
        case rotate(Handle)
        /// Inside the box: drag moves it.
        case move
        case none
    }

    /// Classify a point.
    ///
    /// The rotate zone is a band *outside* each grip. Putting it there rather
    /// than inside means the two never compete for the same pixel: resizing is
    /// what you want when aiming at the box, straightening is what you want when
    /// aiming just past it, and neither can be triggered by a shaky hand on the
    /// other.
    public static func zone(
        at point: CGPoint, in rect: CGRect, tolerance: CGSize, rotateBand: CGSize
    ) -> Zone {
        if let handle = handle(at: point, in: rect, tolerance: tolerance), handle != .interior {
            return .resize(handle)
        }
        // Outside the box only: a point inside it that missed every grip is a
        // move, not a rotate.
        if !rect.contains(point) {
            let outer = CGSize(width: tolerance.width + rotateBand.width,
                               height: tolerance.height + rotateBand.height)
            if let handle = handle(at: point, in: rect, tolerance: outer), handle != .interior {
                return .rotate(handle)
            }
        }
        return rect.contains(point) ? .move : .none
    }

    /// Angle in degrees from `centre` to `point`, measured clockwise from up, in
    /// a space of `aspect` (width ÷ height).
    ///
    /// The aspect correction matters: the box lives in normalized coordinates
    /// where a pane wider than it is tall stretches x, and an angle measured
    /// without undoing that would run fast on one axis and slow on the other —
    /// so a straightening drag would not track the pointer.
    public static func angle(
        of point: CGPoint, about centre: CGPoint, aspect: CGFloat
    ) -> CGFloat {
        let dx = (point.x - centre.x) * max(aspect, 0.0001)
        let dy = point.y - centre.y
        guard dx != 0 || dy != 0 else { return 0 }
        return atan2(dx, -dy) * 180 / .pi
    }

    /// Apply a drag to the box.
    ///
    /// Moving keeps the size and slides within the frame; resizing moves only
    /// the sides its grip owns. Either way the result stays inside the unit
    /// square and no smaller than `minSize`.
    public static func dragged(
        _ rect: CGRect, handle: Handle, by delta: CGSize
    ) -> CGRect {
        guard handle != .interior else { return moved(rect, by: delta) }

        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX += delta.width }
        if handle.movesRight { maxX += delta.width }
        if handle.movesTop { minY += delta.height }
        if handle.movesBottom { maxY += delta.height }

        // Clamp each moving side against the frame *and* against its opposite,
        // so a corner dragged across the box stops rather than inverting it. An
        // inverted rect has a negative width, which every consumer downstream
        // would have to defend against separately.
        if handle.movesLeft { minX = min(max(minX, 0), maxX - minSize) }
        if handle.movesRight { maxX = max(min(maxX, 1), minX + minSize) }
        if handle.movesTop { minY = min(max(minY, 0), maxY - minSize) }
        if handle.movesBottom { maxY = max(min(maxY, 1), minY + minSize) }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Slide the box without resizing it, stopping at the frame's edges.
    public static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        let w = min(rect.width, 1), h = min(rect.height, 1)
        let x = min(max(rect.minX + delta.width, 0), 1 - w)
        let y = min(max(rect.minY + delta.height, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Nudge by whole pixels of `frame`, for arrow-key adjustment.
    public static func nudged(
        _ rect: CGRect, handle: Handle, byPixels pixels: CGVector, in frame: CGSize
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return rect }
        return dragged(rect, handle: handle,
                       by: CGSize(width: pixels.dx / frame.width,
                                  height: pixels.dy / frame.height))
    }

    /// Grow a rect by a fraction of its own size, evenly on all sides.
    ///
    /// A detected edge lands on the boundary it found, which is where the
    /// picture stops — so a crop taken exactly there is liable to shave a row of
    /// it off, and film is not always cut square enough for the last row to be
    /// worth defending. A little slack costs a sliver of rebate and is easy to
    /// pull back in by hand; the reverse isn't.
    ///
    /// The fraction is of the box, not the frame, so the slack stays
    /// proportional whether the negative is 35mm or 8×10.
    public static func expanded(_ rect: CGRect, byFraction f: Double) -> CGRect {
        guard f != 0, rect.width > 0, rect.height > 0 else { return rect }
        return rect
            .insetBy(dx: -rect.width * f / 2, dy: -rect.height * f / 2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Bring a rect back inside the frame and up to the minimum size, for a box
    /// arriving from detection rather than from a drag.
    public static func sanitised(_ rect: CGRect) -> CGRect {
        let w = min(max(rect.width, minSize), 1)
        let h = min(max(rect.height, minSize), 1)
        let x = min(max(rect.minX, 0), 1 - w)
        let y = min(max(rect.minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension PreviewRotation {
    /// A sensor-space rect as it appears on screen.
    ///
    /// Rotation here is always a quarter turn, so a rect maps to a rect and the
    /// corners alone determine it. Rects rather than points are what the crop
    /// editor needs: it can then work wholly in display space, where the grips
    /// mean what they look like, and convert once on the way in and out.
    public func displayRect(fromSensor r: CGRect) -> CGRect {
        Self.span(displayPoint(fromSensor: CGPoint(x: r.minX, y: r.minY)),
                  displayPoint(fromSensor: CGPoint(x: r.maxX, y: r.maxY)))
    }

    public func sensorRect(fromDisplay r: CGRect) -> CGRect {
        Self.span(sensorPoint(fromDisplay: CGPoint(x: r.minX, y: r.minY)),
                  sensorPoint(fromDisplay: CGPoint(x: r.maxX, y: r.maxY)))
    }

    private static func span(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
