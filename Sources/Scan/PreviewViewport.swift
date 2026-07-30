import Foundation
import CoreGraphics

/// Which part of the frame is on screen when the preview is zoomed in.
///
/// At `Fit` the whole frame is visible and the pane letterboxes to its aspect
/// ratio. Zoomed in, the pane instead *fills* the window and shows a window onto
/// the frame — so the visible region has the **pane's** aspect ratio, not the
/// frame's, and something has to say which part of the frame that window covers.
/// That's this.
///
/// All rects and points are normalized [0,1]² in the frame's own space, y-down,
/// matching every other coordinate in the app.
public enum PreviewViewport {

    /// The visible window onto the frame.
    ///
    /// - Parameters:
    ///   - frame: frame size in pixels.
    ///   - pane: pane size in points.
    ///   - scale: displayed points per frame pixel. 1.0 is one frame pixel per
    ///     point, i.e. "100%".
    ///   - center: desired centre of the window, normalized.
    ///
    /// The window is clamped to stay inside the frame, and never exceeds it — so
    /// when the pane is larger than the frame at this scale, the whole frame is
    /// returned rather than a window hanging off the edge.
    public static func visibleRect(
        frame: CGSize, pane: CGSize, scale: CGFloat, center: CGPoint
    ) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard frame.width > 0, frame.height > 0,
              pane.width > 0, pane.height > 0, scale > 0 else { return full }

        // How much of the frame fits in the pane at this scale, as a fraction.
        let w = min(1, pane.width / (frame.width * scale))
        let h = min(1, pane.height / (frame.height * scale))
        let size = CGSize(width: w, height: h)
        let c = clampCenter(center, visibleSize: size)
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    /// Nudge a centre point so a window of `visibleSize` around it stays wholly
    /// inside the frame. An axis where the window covers everything is pinned to
    /// the middle, since there's nothing to pan along it.
    public static func clampCenter(_ center: CGPoint, visibleSize: CGSize) -> CGPoint {
        func clamp(_ v: CGFloat, _ extent: CGFloat) -> CGFloat {
            guard extent < 1 else { return 0.5 }
            let half = extent / 2
            return min(max(v, half), 1 - half)
        }
        return CGPoint(
            x: clamp(center.x, visibleSize.width),
            y: clamp(center.y, visibleSize.height)
        )
    }

    /// True when the window is smaller than the frame on either axis, i.e.
    /// there is somewhere to pan to and a navigator is worth showing.
    public static func isPannable(visibleSize: CGSize) -> Bool {
        visibleSize.width < 0.999 || visibleSize.height < 0.999
    }

    /// Size for the navigator thumbnail, preserving `frameAspect` and fitting
    /// within `maxSize`.
    ///
    /// Small on purpose: it's an overview sitting on top of the picture, and a
    /// large one would cover the thing being examined.
    public static func thumbnailSize(frameAspect: CGFloat, maxSize: CGSize) -> CGSize {
        guard frameAspect > 0, maxSize.width > 0, maxSize.height > 0 else { return .zero }
        let byWidth = CGSize(width: maxSize.width, height: maxSize.width / frameAspect)
        if byWidth.height <= maxSize.height { return byWidth }
        return CGSize(width: maxSize.height * frameAspect, height: maxSize.height)
    }

    /// Move the pan centre by a scroll gesture over the preview itself.
    ///
    /// `delta` is in points, in AppKit's scroll convention: positive means the
    /// content is being pushed down/right, which reveals what's *above* and to
    /// the left — so the centre moves the other way, exactly as a scroll view
    /// behaves. Scaling by the visible fraction over the pane size makes the
    /// image travel the distance scrolled, so the picture keeps up with the
    /// gesture at any zoom.
    public static func pannedCenter(
        _ center: CGPoint, byScroll delta: CGSize, visibleSize: CGSize, pane: CGSize
    ) -> CGPoint {
        guard pane.width > 0, pane.height > 0 else {
            return clampCenter(center, visibleSize: visibleSize)
        }
        let dx = delta.width / pane.width * visibleSize.width
        let dy = delta.height / pane.height * visibleSize.height
        return clampCenter(CGPoint(x: center.x - dx, y: center.y - dy),
                           visibleSize: visibleSize)
    }

    /// Convert a drag inside the navigator into a new pan centre.
    ///
    /// `point` is where the pointer is within the thumbnail, in thumbnail
    /// points; the result is a normalized frame centre, clamped so the window
    /// stays in bounds. Dragging the indicator therefore moves it to the
    /// pointer rather than tracking a grab offset — matching how the metering
    /// box already behaves, where a click jumps the box to that spot.
    public static func panCenter(
        forNavigatorPoint point: CGPoint, thumbnailSize: CGSize, visibleSize: CGSize
    ) -> CGPoint {
        guard thumbnailSize.width > 0, thumbnailSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let raw = CGPoint(x: point.x / thumbnailSize.width,
                          y: point.y / thumbnailSize.height)
        return clampCenter(raw, visibleSize: visibleSize)
    }
}
