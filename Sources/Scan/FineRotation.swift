import Foundation
import CoreGraphics
import AppKit

/// Straightening: a rotation of a fraction of a degree, applied on top of the
/// exact quarter turn.
///
/// Kept apart from `PreviewRotation` because the two are different operations
/// wearing the same word. A quarter turn moves pixels to new positions and loses
/// nothing; any other angle has to resample, and every frame it's applied to is
/// slightly softer for it. Separating them means a preview that hasn't been
/// straightened never pays that cost.
///
/// The result keeps the source's dimensions, so the picture's corners rotate out
/// of view rather than the frame growing to hold them. That's what straightening
/// a scan wants: the crop sits well inside the negative, and a canvas that grew
/// with the angle would move the image under a crop box that is trying to stay
/// still.
public enum FineRotation {

    /// Angles smaller than this are treated as none. Guards the common case —
    /// an unstraightened preview — from paying for a resample that would change
    /// nothing.
    public static let negligibleDegrees = 0.01

    public static func rotate(_ cg: CGImage, byDegrees degrees: Double) -> CGImage? {
        guard abs(degrees) >= negligibleDegrees else { return cg }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return cg }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        // Bitmap contexts are y-up, so a clockwise turn on screen is a positive
        // angle here — the opposite of the sign `PreviewRotation` needs, which
        // draws into a context whose axes it has already swapped.
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: CGFloat(degrees) * .pi / 180)
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    public static func rotate(_ image: NSImage, byDegrees degrees: Double) -> NSImage {
        guard abs(degrees) >= negligibleDegrees,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let out = rotate(cg, byDegrees: degrees)
        else { return image }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }
}
