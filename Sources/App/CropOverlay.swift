import SwiftUI
import Scan

/// The adjustable crop box drawn over the live preview.
///
/// Everything here works in **display** space — the rotated view the operator is
/// looking at — so a grip on the left of the screen moves the left of the box
/// whatever the preview's rotation.
///
/// The view covers the whole pane rather than just the picture, and works out
/// where the picture sits inside it. That's not cosmetic: the rotate handles
/// live in a band *outside* the box, and a crop taken right up to the edge of
/// the negative puts that band in the letterbox. Clipped to the picture, the
/// overlay never receives the pointer there and those handles simply don't
/// exist — measured on a real negative framed to the right-hand edge, where
/// straightening from that side was impossible.
struct CropOverlay: View {
    /// The crop in display space, normalized and y-down.
    @Binding var rect: CGRect
    /// Straightening of the picture underneath, in degrees clockwise. Driven by
    /// the rotate zones just outside the box.
    @Binding var fineRotation: Double
    /// Aspect ratio of the displayed frame, for finding the picture within the
    /// pane.
    let imageAspect: CGFloat
    /// While false the box is only drawn, not edited: no handles, no dimming,
    /// and no pointer taken. The overlay covers the whole pane, so leaving it
    /// interactive after the crop is settled would put it between the operator
    /// and the eyedropper, the metering box and everything else underneath.
    let isEditing: Bool

    /// Grip size on screen. Independent of the pane's size, so the target stays
    /// the same however the window is scaled.
    private static let handleLength: CGFloat = 22
    private static let handleThickness: CGFloat = 4
    /// Extra grab room around each grip, in points. A 4pt bar is far too fine to
    /// hit reliably with a mouse.
    private static let grabPadding: CGFloat = 8

    /// Reach of the rotate band beyond each grip, in points.
    private static let rotateBand: CGFloat = 26

    @State private var dragging: CropBox.Handle?
    @State private var dragOrigin: CGRect?
    /// Set while a straightening drag is in progress: the angle the pointer
    /// started at, and the rotation at that moment.
    @State private var rotateStart: (angle: CGFloat, rotation: Double)?
    @State private var hoverZone: CropBox.Zone = .none

    var body: some View {
        GeometryReader { geo in
            let pane = geo.size
            let image = PreviewViewport.fittedRect(aspect: imageAspect, in: pane)
            let box = CGRect(x: image.minX + rect.minX * image.width,
                             y: image.minY + rect.minY * image.height,
                             width: rect.width * image.width,
                             height: rect.height * image.height)
            ZStack(alignment: .topLeading) {
                if isEditing {
                    dimming(box: box, image: image)
                    thirds(box: box)
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                        .frame(width: box.width, height: box.height)
                        .offset(x: box.minX, y: box.minY)
                    handles(box: box)
                } else {
                    appliedOutline(box: box)
                }
            }
            .contentShape(Rectangle())
            .modifier(CropInteraction(enabled: isEditing,
                                      gesture: drag(pane: pane, image: image)))
            // Continuous rather than a plain `onHover`, because the cursor
            // depends on *where* in the overlay the pointer is, not merely
            // whether it's inside. Setting it on every event also survives
            // SwiftUI resetting the cursor as the pointer crosses subviews.
            .onContinuousHover { phase in
                guard isEditing else { return }
                switch phase {
                case .active(let location):
                    hoverZone = zone(at: location, image: image)
                    (CropCursors.cursor(for: hoverZone) ?? NSCursor.arrow).set()
                case .ended:
                    hoverZone = .none
                    NSCursor.arrow.set()
                }
            }
        }
    }

    /// The applied crop: a hairline white rectangle with a black one just
    /// outside it.
    ///
    /// Two colours because one is never enough here — a white line disappears
    /// into clear film base and a black one into a dense frame, and a single
    /// negative routinely has both within a few pixels of the crop's edge.
    @ViewBuilder
    private func appliedOutline(box: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.black, lineWidth: 1)
                .frame(width: box.width + 2, height: box.height + 2)
                .offset(x: box.minX - 1, y: box.minY - 1)
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Pieces

    /// The picture outside the crop, darkened. Drawn as four rectangles rather
    /// than an even-odd mask so it composites cheaply over a 30fps stream.
    ///
    /// Bounded to the picture, not the pane: the letterbox is already black, and
    /// shading it too would make the negative look smaller than it is.
    @ViewBuilder
    private func dimming(box: CGRect, image: CGRect) -> some View {
        let shade = Color.black.opacity(0.45)
        ZStack(alignment: .topLeading) {
            shade.frame(width: image.width, height: max(box.minY - image.minY, 0))
                .offset(x: image.minX, y: image.minY)
            shade.frame(width: image.width, height: max(image.maxY - box.maxY, 0))
                .offset(x: image.minX, y: box.maxY)
            shade.frame(width: max(box.minX - image.minX, 0), height: box.height)
                .offset(x: image.minX, y: box.minY)
            shade.frame(width: max(image.maxX - box.maxX, 0), height: box.height)
                .offset(x: box.maxX, y: box.minY)
        }
        .allowsHitTesting(false)
    }

    /// Thirds, the usual guide for judging where a frame's edges sit.
    @ViewBuilder
    private func thirds(box: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = box.minX + box.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: box.minY))
                p.addLine(to: CGPoint(x: x, y: box.maxY))
                let y = box.minY + box.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: box.minX, y: y))
                p.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        .allowsHitTesting(false)
    }

    /// Eight grips: a corner bracket at each corner and a bar at the middle of
    /// each edge, so it's visible at a glance which one moves a side and which
    /// moves two.
    @ViewBuilder
    private func handles(box: CGRect) -> some View {
        ForEach(CropBox.handlePositions(in: CGRect(x: 0, y: 0, width: 1, height: 1)),
                id: \.0) { handle, unit in
            let p = CGPoint(x: box.minX + unit.x * box.width,
                            y: box.minY + unit.y * box.height)
            let size = handleSize(handle)
            Rectangle()
                .fill(Color.white)
                .frame(width: size.width, height: size.height)
                .offset(x: p.x - size.width / 2, y: p.y - size.height / 2)
                .shadow(color: .black.opacity(0.6), radius: 1)
        }
        .allowsHitTesting(false)
    }

    private func handleSize(_ handle: CropBox.Handle) -> CGSize {
        switch handle {
        case .left, .right:
            return CGSize(width: Self.handleThickness, height: Self.handleLength)
        case .top, .bottom:
            return CGSize(width: Self.handleLength, height: Self.handleThickness)
        default:
            return CGSize(width: Self.handleThickness * 2.5, height: Self.handleThickness * 2.5)
        }
    }

    // MARK: - Dragging

    /// Pane point to picture-normalized. Values outside 0...1 are meaningful
    /// here — that's the letterbox, where the rotate handles live.
    private func normalized(_ location: CGPoint, in image: CGRect) -> CGPoint {
        CGPoint(x: (location.x - image.minX) / max(image.width, 1),
                y: (location.y - image.minY) / max(image.height, 1))
    }

    private func zone(at location: CGPoint, image: CGRect) -> CropBox.Zone {
        guard image.width > 0, image.height > 0 else { return .none }
        return CropBox.zone(at: normalized(location, in: image), in: rect,
                            tolerance: tolerance(image: image), rotateBand: band(image: image))
    }

    private func tolerance(image: CGRect) -> CGSize {
        CGSize(width: (Self.handleLength / 2 + Self.grabPadding) / max(image.width, 1),
               height: (Self.handleLength / 2 + Self.grabPadding) / max(image.height, 1))
    }

    private func band(image: CGRect) -> CGSize {
        CGSize(width: Self.rotateBand / max(image.width, 1),
               height: Self.rotateBand / max(image.height, 1))
    }

    private func drag(pane: CGSize, image: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard image.width > 0, image.height > 0 else { return }
                // The grip is chosen once, at the start. Re-deciding on every
                // change would let the box hand the drag to a different grip
                // mid-gesture as the pointer moves past one.
                if dragging == nil, rotateStart == nil {
                    switch zone(at: value.startLocation, image: image) {
                    case .resize(let handle):
                        dragging = handle
                        dragOrigin = rect
                    case .move:
                        dragging = .interior
                        dragOrigin = rect
                    case .rotate:
                        rotateStart = (CropBox.angle(
                            of: normalized(value.startLocation, in: image),
                            about: CGPoint(x: rect.midX, y: rect.midY),
                            aspect: image.width / max(image.height, 1)), fineRotation)
                    case .none:
                        return
                    }
                }
                // Straightening: the angle swept about the box's centre, added
                // to where the rotation stood when the drag began. Measured from
                // the start rather than accumulated per event, so clamping at
                // the limit doesn't make the picture drift.
                if let start = rotateStart {
                    let angle = CropBox.angle(
                        of: normalized(value.location, in: image),
                        about: CGPoint(x: rect.midX, y: rect.midY),
                        aspect: image.width / max(image.height, 1))
                    var swept = Double(angle - start.angle)
                    // Shortest way round, so passing 180° doesn't spin the
                    // picture the long way.
                    if swept > 180 { swept -= 360 } else if swept < -180 { swept += 360 }
                    // Subtracted, not added: the drag turns the *crop frame*,
                    // and the picture inside it therefore moves the other way.
                    // Dragging the handle clockwise brings a film edge that
                    // leans right back to level, which is the way round every
                    // straighten tool works and the way round the hand expects.
                    fineRotation = start.rotation - swept
                    return
                }
                guard let handle = dragging, let origin = dragOrigin else { return }
                // Measured from where the drag *started*, against the rect as it
                // was then. Accumulating per-change deltas instead drifts, since
                // each one is clamped before the next is added.
                let delta = CGSize(width: value.translation.width / image.width,
                                   height: value.translation.height / image.height)
                rect = CropBox.dragged(origin, handle: handle, by: delta)
            }
            .onEnded { _ in
                dragging = nil
                dragOrigin = nil
                rotateStart = nil
            }
    }
}

/// Attaches the crop's drag gesture only while it's being edited.
///
/// A `.gesture` that is merely disabled still claims the pointer, so the layers
/// underneath — the eyedropper, the metering box — would never see a click. The
/// gesture has to be absent rather than inert.
private struct CropInteraction<G: Gesture>: ViewModifier {
    let enabled: Bool
    let gesture: G

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(gesture)
        } else {
            content.allowsHitTesting(false)
        }
    }
}
