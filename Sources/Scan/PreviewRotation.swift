import Foundation
import AppKit

/// Quarter-turn rotation applied to the live-view preview.
///
/// This is a *display* transform only. Nothing is written to the camera and
/// captured files are never re-encoded — the body still hands us frames and
/// RAWs in its native orientation, and the rotation travels alongside the scan
/// as metadata so downstream tools know which way is up.
///
/// The important structural rule: everything upstream of the final compose step
/// stays in **unrotated sensor space** — metering centre, the `eoszoomposition`
/// calibration, focus peaking, and (later) crop geometry. Only the last blit and
/// the pointer/arrow-key mapping know rotation exists. That keeps the hard-won
/// zoom calibration in AppModel valid at every rotation without re-measuring it.
///
/// Both coordinate spaces referenced below are normalized [0,1]² and **y-down**
/// (SwiftUI/AppKit event convention, matching `AppModel.meteringCenter`).
public enum PreviewRotation: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case cw90 = 90
    case cw180 = 180
    case cw270 = 270

    /// Next quarter turn clockwise, wrapping 270° → 0°.
    public var rotatedRight: PreviewRotation {
        switch self {
        case .none: return .cw90
        case .cw90: return .cw180
        case .cw180: return .cw270
        case .cw270: return .none
        }
    }

    /// Next quarter turn counter-clockwise, wrapping 0° → 270°.
    public var rotatedLeft: PreviewRotation {
        switch self {
        case .none: return .cw270
        case .cw90: return .none
        case .cw180: return .cw90
        case .cw270: return .cw180
        }
    }

    /// True for the quarter turns that swap the frame's width and height, so
    /// callers know a 3:2 sensor frame displays as 2:3.
    public var swapsAxes: Bool { self == .cw90 || self == .cw270 }

    /// Compact label for the toolbar button and menu items.
    public var displayName: String { "\(rawValue)°" }

    /// Aspect ratio to display a sensor frame of `sensorAspect` (width ÷ height)
    /// at this rotation.
    public func displayAspect(sensorAspect: CGFloat) -> CGFloat {
        swapsAxes ? 1 / sensorAspect : sensorAspect
    }

    // MARK: - Point mapping

    /// Map a point in unrotated **sensor** space to where it appears in the
    /// **displayed** (rotated) frame.
    ///
    /// Derivation for `.cw90`: rotating the image a quarter turn clockwise sends
    /// the sensor's top-left corner to the display's top-right, so
    /// (0,0) → (1,0) and (1,0) → (1,1). That is (x,y) → (1−y, x).
    public func displayPoint(fromSensor p: CGPoint) -> CGPoint {
        switch self {
        case .none:  return p
        case .cw90:  return CGPoint(x: 1 - p.y, y: p.x)
        case .cw180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .cw270: return CGPoint(x: p.y, y: 1 - p.x)
        }
    }

    /// Inverse of `displayPoint(fromSensor:)` — turns a click in the rotated
    /// preview back into the sensor coordinate the camera understands.
    public func sensorPoint(fromDisplay p: CGPoint) -> CGPoint {
        switch self {
        case .none:  return p
        case .cw90:  return CGPoint(x: p.y, y: 1 - p.x)
        case .cw180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .cw270: return CGPoint(x: 1 - p.y, y: p.x)
        }
    }

    /// Map a *direction* the user expressed on screen (e.g. an arrow key) into
    /// sensor space. This is the linear part of `sensorPoint(fromDisplay:)`
    /// with the translations dropped, so "up" always moves things up on screen
    /// no matter how the preview is turned.
    public func sensorDelta(fromDisplay d: CGVector) -> CGVector {
        switch self {
        case .none:  return d
        case .cw90:  return CGVector(dx: d.dy, dy: -d.dx)
        case .cw180: return CGVector(dx: -d.dx, dy: -d.dy)
        case .cw270: return CGVector(dx: -d.dy, dy: d.dx)
        }
    }

    // MARK: - Image rotation

    /// Rotate a composed preview frame for display. Returns the input untouched
    /// at `.none` (the common case) and on any decode failure, so a bad frame
    /// degrades to an unrotated preview rather than a black pane.
    public func rotate(_ image: NSImage) -> NSImage {
        guard self != .none else { return image }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        guard let rotated = rotate(cg) else { return image }
        return NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
    }

    /// Bitmap rotation. Kept separate from the `NSImage` wrapper so tests can
    /// assert pixel placement directly.
    ///
    /// The destination context is y-up, which is Core Graphics' default for a
    /// bitmap context, so a *visual* clockwise turn is a negative rotation
    /// angle. Output is forced to device RGB rather than inheriting the source
    /// colour space, because a grayscale or CMYK source would not accept the
    /// 32-bit bitmapInfo below.
    public func rotate(_ cg: CGImage) -> CGImage? {
        guard self != .none else { return cg }
        let w = cg.width, h = cg.height
        let outW = swapsAxes ? h : w
        let outH = swapsAxes ? w : h
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none   // exact quarter turn: no resampling needed
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: -CGFloat(rawValue) * .pi / 180)
        ctx.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                                width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}
