import SwiftUI
import AppKit
import Camera

/// Wraps an NSImageView for the live-view stream, SwiftUI's `Image` repaint cycle is too
/// slow for a 10fps JPEG stream. Falls back to a placeholder when not streaming.
///
/// Overlay (SwiftUI layer ABOVE the NSImageView): a rectangle showing the
/// metering / zoom region. It indicates what area is being metered and zoomed,
/// can be hidden/shown easily, and can be moved so center metering isn't
/// the only option.
///
/// First pass: static center rectangle, toggleable via Cmd-H / H or via a
/// menu item. Drag-to-move and per-shot persistence are follow-ups.
struct LiveViewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            // 3:2 aspect-ratio constraint so the pane letterboxes inside the
            // available space instead of cropping.
            ImagePaneRepresentable()
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
            // Interaction layer ONLY, same 3:2 rect as the image. The visible
            // box is composited into the frame (AppModel.drawZoomBox), always
            // shown while the overlay toggle is on (no fade). Click OR drag
            // anywhere to zip the box (zoom target), centered, to that point.
            if model.showMeteringOverlay && model.isLiveViewOn && model.zoomMode == .fit {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)   // 0 → a plain click also fires this
                                .onChanged { value in
                                    let f = AppModel.zoomBoxFraction
                                    let cx = value.location.x / max(geo.size.width, 1)
                                    let cy = value.location.y / max(geo.size.height, 1)
                                    // Box centered on the click/drag point, clamped so it
                                    // stays fully in frame and can reach every edge.
                                    let nx = min(max(cx, f/2), 1 - f/2)
                                    let ny = min(max(cy, f/2), 1 - f/2)
                                    model.meteringCenter = CGPoint(x: nx, y: ny)
                                }
                        )
                }
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
            }
        }
    }
}

private struct ImagePaneRepresentable: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> ImagePane {
        let pane = ImagePane()
        // scaleProportionallyUpOrDown = always scale to fit, preserve aspect,
        // never crop. Belt-and-suspenders: SwiftUI also gets an
        // aspectRatio(3/2) constraint in LiveViewPane.body so the pane
        // itself is letterboxed inside the available space rather than
        // sized to whatever the parent provides. Together: never crop.
        pane.imageScaling = .scaleProportionallyUpOrDown
        pane.imageAlignment = .alignCenter
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.black.cgColor
        return pane
    }

    func updateNSView(_ nsView: ImagePane, context: Context) {
        nsView.image = model.latestFrame
    }

    final class ImagePane: NSImageView {
        override var acceptsFirstResponder: Bool { true }
    }
}


