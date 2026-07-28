import Foundation
import CoreGraphics

/// Reads colour back out of a decoded frame, for the click-to-set-white-balance
/// eyedropper.
public enum PixelSampler {

    /// Explicitly sRGB, which is what the camera's preview JPEGs are.
    /// `CGColorSpaceCreateDeviceRGB()` is *not* sRGB on macOS, and reading
    /// through it silently converts: a pure sRGB red comes back as roughly
    /// (0.98, 0.15, 0.20), which would bake a phantom cast into every
    /// white-balance sample.
    static let workingSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    /// Default eyedropper patch, in pixels on a side. A single pixel off a film
    /// scan is mostly grain and sensor noise; averaging a small square is what
    /// makes repeated clicks on the same film base agree with each other.
    public static let defaultPatchSize = 9

    /// Average colour of a square patch centred on `point`, as 0...1 channels.
    ///
    /// `point` is normalized [0,1]² and **y-down**, in the image's own
    /// orientation — callers holding a rotated preview must un-rotate first, so
    /// the sample comes from the pixel the user actually clicked.
    ///
    /// Values are read in the image's encoded (gamma) space rather than being
    /// linearised. That's deliberate: the correction computed from these numbers
    /// is applied by a colour matrix running in the same unmanaged space, so
    /// sampling and applying agree and one click lands neutral. Linearising here
    /// and not there would leave a residual cast.
    ///
    /// Returns nil if the image is empty or the patch can't be rendered.
    public static func averageColor(
        in image: CGImage,
        atNormalized point: CGPoint,
        patchSize: Int = defaultPatchSize
    ) -> (red: Double, green: Double, blue: Double)? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, patchSize > 0 else { return nil }

        // Centre pixel, clamped so a click on the very edge still samples a
        // full patch's worth of real pixels rather than falling off the image.
        let cx = Int((point.x * CGFloat(w)).rounded(.down))
        let cy = Int((point.y * CGFloat(h)).rounded(.down))
        let half = patchSize / 2
        var originX = min(max(cx - half, 0), max(w - patchSize, 0))
        var originY = min(max(cy - half, 0), max(h - patchSize, 0))
        let side = min(patchSize, min(w, h))
        originX = min(originX, w - side)
        originY = min(originY, h - side)

        // CGImage.cropping uses a top-left origin, matching our y-down point.
        guard let patch = image.cropping(
            to: CGRect(x: originX, y: originY, width: side, height: side)
        ) else { return nil }

        let count = side * side
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress,
                width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: workingSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(patch, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew, count > 0 else { return nil }

        var rSum = 0, gSum = 0, bSum = 0
        for i in stride(from: 0, to: count * 4, by: 4) {
            rSum += Int(bytes[i])
            gSum += Int(bytes[i + 1])
            bSum += Int(bytes[i + 2])
        }
        let denom = Double(count) * 255.0
        return (Double(rSum) / denom, Double(gSum) / denom, Double(bSum) / denom)
    }
}
