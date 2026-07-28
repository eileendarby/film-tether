import SwiftUI
import AppKit
import Camera
import Scan

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
            // Aspect-ratio constraint so the pane letterboxes inside the
            // available space instead of cropping. 3:2 normally, 2:3 when the
            // preview is rotated a quarter turn.
            ImagePaneRepresentable()
                .aspectRatio(model.previewAspectRatio, contentMode: .fit)
                .background(paneSizeReporter())
            // Interaction layer ONLY, same rect as the image. The visible
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
                                    // The gesture reports a point in the ROTATED
                                    // view; meteringCenter is sensor space, so
                                    // un-rotate before clamping (clamping in the
                                    // wrong space would pin the wrong edges).
                                    let display = CGPoint(
                                        x: value.location.x / max(geo.size.width, 1),
                                        y: value.location.y / max(geo.size.height, 1)
                                    )
                                    let s = model.previewRotation.sensorPoint(fromDisplay: display)
                                    // Box centered on the click/drag point, clamped so it
                                    // stays fully in frame and can reach every edge.
                                    let nx = min(max(s.x, f/2), 1 - f/2)
                                    let ny = min(max(s.y, f/2), 1 - f/2)
                                    model.meteringCenter = CGPoint(x: nx, y: ny)
                                }
                        )
                }
                .aspectRatio(model.previewAspectRatio, contentMode: .fit)
            }
        }
    }

    /// Publishes the pane's laid-out size to the model so the zoom button can
    /// show a real "Fit (N%)". It has to come from actual geometry: the number
    /// changes with every window resize and every rotation.
    private func paneSizeReporter() -> some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size, initial: true) { _, newValue in
                    guard model.previewPaneSize != newValue else { return }
                    model.previewPaneSize = newValue
                }
        }
    }
}

private struct ImagePaneRepresentable: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> ImagePane {
        let pane = ImagePane()
        pane.imageAlignment = .alignCenter
        pane.wantsLayer = true
        pane.layer?.backgroundColor = NSColor.black.cgColor
        // At 100% the image is routinely larger than the pane, so the overflow
        // has to be clipped rather than drawn over the toolbar.
        pane.layer?.masksToBounds = true
        return pane
    }

    func updateNSView(_ nsView: ImagePane, context: Context) {
        nsView.image = model.latestFrame
        // .scaleNone draws one image pixel per point — that's what "100%" means
        // here. Fit and the 5× punch-in both scale to the pane instead.
        nsView.imageScaling = model.previewZoom == .actual
            ? .scaleNone
            : .scaleProportionallyUpOrDown
    }

    final class ImagePane: NSImageView {
        override var acceptsFirstResponder: Bool { true }

        /// NSImageView reports the image's pixel size as its intrinsic size,
        /// which SwiftUI honours — so a rotated (tall) frame or a frame larger
        /// than the pane grew the VStack past the window and pushed the toolbar
        /// and status footer off-screen. The enclosing SwiftUI `aspectRatio`
        /// already decides how big this view should be, so opt out entirely.
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }
}
