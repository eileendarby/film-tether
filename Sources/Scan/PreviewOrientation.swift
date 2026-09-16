import Foundation
import CoreGraphics
import AppKit

/// How the sensor frame is turned for display: if the film came off the
/// sensor mirrored, a left-to-right mirror first, then the quarter turn —
/// the archive's order (`flop`, then `rotate`). The order matters: a mirror
/// and a quarter turn don't commute, the two orders differ by a half turn,
/// and being about the centre is what makes the difference exactly that.
///
/// Everything that maps between what's on screen and the sensor — the
/// metering box, the crop box, the eyedropper — goes through this rather
/// than `PreviewRotation` directly, so a mirrored preview keeps its overlays
/// on the film they were put on.
public struct PreviewOrientation: Equatable, Sendable {
    public var rotation: PreviewRotation
    public var mirrored: Bool

    public init(rotation: PreviewRotation, mirrored: Bool) {
        self.rotation = rotation
        self.mirrored = mirrored
    }

    public var isIdentity: Bool { rotation == .none && !mirrored }

    public func displayAspect(sensorAspect: CGFloat) -> CGFloat {
        rotation.displayAspect(sensorAspect: sensorAspect)
    }

    // MARK: - Point mapping

    public func displayPoint(fromSensor p: CGPoint) -> CGPoint {
        rotation.displayPoint(fromSensor: mirrored ? CGPoint(x: 1 - p.x, y: p.y) : p)
    }

    public func sensorPoint(fromDisplay p: CGPoint) -> CGPoint {
        let s = rotation.sensorPoint(fromDisplay: p)
        return mirrored ? CGPoint(x: 1 - s.x, y: s.y) : s
    }

    /// A direction on screen, in sensor terms. The mirror reverses the
    /// sensor's left and right, after the turn has been undone.
    public func sensorDelta(fromDisplay d: CGVector) -> CGVector {
        let s = rotation.sensorDelta(fromDisplay: d)
        return mirrored ? CGVector(dx: -s.dx, dy: s.dy) : s
    }

    public func displayRect(fromSensor r: CGRect) -> CGRect {
        Self.span(displayPoint(fromSensor: CGPoint(x: r.minX, y: r.minY)),
                  displayPoint(fromSensor: CGPoint(x: r.maxX, y: r.maxY)))
    }

    public func sensorRect(fromDisplay r: CGRect) -> CGRect {
        Self.span(sensorPoint(fromDisplay: CGPoint(x: r.minX, y: r.minY)),
                  sensorPoint(fromDisplay: CGPoint(x: r.maxX, y: r.maxY)))
    }

    /// A display-space rect as it appears once the mirror is switched on or
    /// off under it. The mirror is in sensor space, before the turn, so on
    /// screen it reads left-to-right at 0° and 180° and top-to-bottom at 90°
    /// and 270°.
    public func mirrorToggledDisplayRect(_ r: CGRect) -> CGRect {
        if rotation == .cw90 || rotation == .cw270 {
            return CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        }
        return CGRect(x: 1 - r.maxX, y: r.minY, width: r.width, height: r.height)
    }

    private static func span(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Image

    /// Turn and, if needed, mirror a frame for display. The input comes back
    /// untouched for the identity and on any failure, so a bad frame degrades
    /// to an unturned preview rather than a black pane.
    public func apply(_ image: NSImage) -> NSImage {
        guard !isIdentity else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let out = apply(cg) else { return image }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    public func apply(_ cg: CGImage) -> CGImage? {
        guard let base = mirrored ? Self.mirror(cg) : cg else { return nil }
        return rotation.rotate(base)
    }

    /// Reflect left to right. Same bitmap setup as `PreviewRotation.rotate`:
    /// forced to device RGB so any source colour space is accepted.
    public static func mirror(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
