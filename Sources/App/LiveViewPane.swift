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
            // At 100% the pane fills the space and AppModel crops the frame to
            // match: you're looking at a window onto part of the negative, so
            // preserving the frame's shape would only waste screen. The
            // navigator below is what then tells you which part you're on.
            //
            // Fit and 500% both letterbox to the frame's aspect ratio (3:2, or
            // 2:3 rotated). At 500% that's because the body already sends just
            // the magnified region, in its own 3:2 shape — filling the pane
            // would mean cropping away pixels it went to the trouble of
            // magnifying.
            Group {
                if model.previewZoom == .actual {
                    ImagePaneRepresentable()
                } else {
                    ImagePaneRepresentable()
                        .aspectRatio(model.previewAspectRatio, contentMode: .fit)
                }
            }
            .background(paneSizeReporter())
            // Eyedropper takes over the whole pane while armed, so a click
            // samples white balance instead of moving the metering box. It
            // outranks the metering layer deliberately: the two would otherwise
            // fight over the same click.
            if model.isPickingWhiteBalance && model.isLiveViewOn {
                EyedropperLayer { display in
                    // Un-rotate so the sample comes from the pixel that
                    // was actually under the crosshair.
                    let s = model.previewRotation.sensorPoint(fromDisplay: display)
                    model.sampleWhiteBalance(atSensor: s)
                }
                .aspectRatio(model.previewAspectRatio, contentMode: .fit)
            }
            // Interaction layer ONLY, same rect as the image. The visible
            // box is composited into the frame (AppModel.drawZoomBox), always
            // shown while the overlay toggle is on (no fade). Click OR drag
            // anywhere to zip the box (zoom target), centered, to that point.
            // Not at 100%: there the pane is a *window* onto the frame, so a
            // click's position over the pane is not its position in the frame
            // and this layer would move the box somewhere the operator didn't
            // point. Keeping it off also leaves the pane free to take scroll
            // events, which is how panning works at that zoom.
            else if model.showMeteringOverlay && model.isLiveViewOn
                        && model.zoomMode == .fit && model.previewZoom != .actual {
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
            // Overview of the whole frame with the visible region marked, sat in
            // the bottom-right corner. Only while zoomed, and only when there's
            // somewhere to pan to.
            if model.isPreviewPannable, let thumb = model.navigatorThumbnail {
                NavigatorOverlay(thumbnail: thumb,
                                 region: model.previewVisibleRegion) { center in
                    Task { await model.setPreviewPanCenter(center) }
                }
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

/// Overview of the whole frame with the on-screen region marked, for navigating
/// while zoomed in.
///
/// It sits in the bottom-right corner of the pane, small enough not to hide the
/// negative. Dragging (or clicking) inside it moves the region to the pointer —
/// the same jump-to-here behaviour the metering box already has, rather than
/// tracking a grab offset.
private struct NavigatorOverlay: View {
    /// Whole frame, already rotated for display.
    let thumbnail: NSImage
    /// Region currently on screen, normalized in the thumbnail's own space.
    let region: CGRect
    let onPan: (CGPoint) -> Void

    /// Budget for the thumbnail's longest side. Big enough to make out where
    /// you are in a strip of negatives, small enough to sit on top of one.
    private static let maxSize = CGSize(width: 180, height: 180)
    private static let inset: CGFloat = 12

    private var size: CGSize {
        let s = thumbnail.size
        guard s.width > 0, s.height > 0 else { return .zero }
        return PreviewViewport.thumbnailSize(
            frameAspect: s.width / s.height, maxSize: Self.maxSize)
    }

    var body: some View {
        let size = self.size
        if size.width > 0, size.height > 0 {
            Image(nsImage: thumbnail)
                .resizable()
                .frame(width: size.width, height: size.height)
                .overlay(indicator(in: size))
                .overlay(Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1))
                .shadow(radius: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)   // 0 → a plain click pans too
                        .onChanged { value in
                            onPan(PreviewViewport.panCenter(
                                forNavigatorPoint: value.location,
                                thumbnailSize: size,
                                visibleSize: CGSize(width: region.width,
                                                    height: region.height)
                            ))
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)
                .padding(Self.inset)
        }
    }

    /// White box over the part of the frame that's on screen. Drawn in the
    /// thumbnail's coordinates, so it needs no knowledge of the pane.
    private func indicator(in size: CGSize) -> some View {
        Rectangle()
            .stroke(Color.white, lineWidth: 2)
            .frame(width: max(region.width * size.width, 4),
                   height: max(region.height * size.height, 4))
            .position(x: region.midX * size.width,
                      y: region.midY * size.height)
    }
}

/// Click target for the white-balance eyedropper, showing a crosshair cursor so
/// it's unambiguous which pixel is about to be sampled.
///
/// The crosshair is pushed on hover and popped on exit. `NSCursor.push()` is a
/// *stack*, so an unbalanced pop leaks the cursor to the whole app — hence the
/// `pushed` flag guarding both directions, plus the `onDisappear` cleanup. That
/// last one is what actually matters in practice: taking a sample disarms the
/// picker, so this view is usually torn down while the pointer is still inside
/// it and no hover-exit ever arrives.
private struct EyedropperLayer: View {
    /// Called with the click position, normalized to the pane and y-down.
    let onPick: (CGPoint) -> Void

    @State private var pushed = false

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside, !pushed {
                        NSCursor.crosshair.push()
                        pushed = true
                    } else if !inside, pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onTapGesture { location in
                    onPick(CGPoint(
                        x: location.x / max(geo.size.width, 1),
                        y: location.y / max(geo.size.height, 1)
                    ))
                }
        }
        .onDisappear {
            if pushed {
                NSCursor.pop()
                pushed = false
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
        // Scrolling and middle-drag both pan the zoomed preview. Handled down
        // here in AppKit rather than as SwiftUI gestures: SwiftUI has no scroll
        // gesture outside a ScrollView (and wrapping the pane in one would hand
        // it a scrolling content size we don't want), and it can't see the
        // middle mouse button at all.
        nsView.onPanBy = { [model] delta in model.scrollPreview(by: delta) }
        nsView.canPan = model.isPreviewPannable
    }

    final class ImagePane: NSImageView {
        override var acceptsFirstResponder: Bool { true }

        /// Pan the preview by a distance in points, y-down.
        var onPanBy: ((CGSize) -> Void)?
        /// False at Fit, where there's nowhere to pan — events then go to the
        /// responder chain instead of being quietly eaten.
        var canPan = false

        /// Points to travel per unit of a notched wheel's delta.
        ///
        /// Trackpads and Magic Mice report precise deltas already in points, so
        /// they're used as-is. An old-fashioned wheel reports lines — about 1.0
        /// per notch — which would otherwise move the image by a single pixel.
        private static let pointsPerLine: CGFloat = 40

        override func scrollWheel(with event: NSEvent) {
            guard canPan, let onPanBy else {
                super.scrollWheel(with: event)
                return
            }
            let scale = event.hasPreciseScrollingDeltas ? 1 : Self.pointsPerLine
            onPanBy(CGSize(width: event.scrollingDeltaX * scale,
                           height: event.scrollingDeltaY * scale))
        }

        // MARK: - Middle-button drag

        /// Where the pointer was at the last drag event, in window coordinates.
        /// Deltas are taken from this rather than from `NSEvent.deltaY`, whose
        /// sign convention for mouse movement is the opposite of the scroll
        /// events above — computing both the same way keeps one pan direction.
        private var dragAnchor: NSPoint?
        /// Guards the cursor push/pop. `NSCursor.push()` is a stack, so an
        /// unbalanced pop leaks the cursor to the whole app.
        private var grabCursorPushed = false

        override func otherMouseDown(with event: NSEvent) {
            guard canPan, event.buttonNumber == 2 else {
                super.otherMouseDown(with: event)
                return
            }
            dragAnchor = event.locationInWindow
            if !grabCursorPushed {
                NSCursor.closedHand.push()
                grabCursorPushed = true
            }
        }

        override func otherMouseDragged(with event: NSEvent) {
            guard let anchor = dragAnchor, let onPanBy else {
                super.otherMouseDragged(with: event)
                return
            }
            let now = event.locationInWindow
            dragAnchor = now
            // Window coordinates are y-up; the pan maths is y-down. Dragging
            // then moves the picture with the pointer, which is what a grab is.
            onPanBy(CGSize(width: now.x - anchor.x, height: anchor.y - now.y))
        }

        override func otherMouseUp(with event: NSEvent) {
            guard dragAnchor != nil else {
                super.otherMouseUp(with: event)
                return
            }
            endGrab()
        }

        /// Zooming back to Fit mid-drag, or the view going away entirely, would
        /// otherwise strand the closed-hand cursor.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { endGrab() }
        }

        private func endGrab() {
            dragAnchor = nil
            if grabCursorPushed {
                NSCursor.pop()
                grabCursorPushed = false
            }
        }

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
