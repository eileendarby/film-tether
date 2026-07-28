import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Scan

/// The single host-side pass over each live-view frame: white balance,
/// monochrome, and focus peaking.
///
/// These used to be (or would have become) separate JPEG-to-JPEG steps, each
/// decoding and re-encoding the frame. At 30 fps that's the difference between
/// one decode and three, plus two pointless JPEG round-trips that also threw
/// away quality. Here the frame is decoded once, all requested stages run as
/// one Core Image graph, and one bitmap comes out.
enum PreviewPipeline {

    /// Focus-peaking settings, bundled so `render` takes one optional rather
    /// than three correlated parameters plus an enabled flag.
    struct Peaking {
        var mode: FocusPeaking.Mode
        var intensity: Float
        var color: FocusPeaking.PeakColor
    }

    /// **Colour management is deliberately disabled** (`workingColorSpace` of
    /// null), so filters operate directly on the frame's encoded values.
    ///
    /// This is what makes click-to-set white balance land neutral in one click.
    /// `PixelSampler` reads gamma-encoded sRGB bytes to compute the gains; if
    /// Core Image then applied those gains in *linear* space, a gain of k would
    /// act like k^(1/2.2) — roughly half the correction asked for, leaving a
    /// visible residual cast that no amount of re-clicking would converge away.
    /// Sampling and applying have to agree on the space, and encoded is the one
    /// we can read cheaply.
    private static let context = CIContext(options: [
        .useSoftwareRenderer: false,
        .workingColorSpace: NSNull(),
    ])

    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    /// Render a frame with the requested adjustments.
    ///
    /// Returns nil when there is nothing to do — no adjustments and no peaking —
    /// so the caller can hand the untouched JPEG straight to `NSImage` and skip
    /// Core Image entirely. That's the common case and it should cost nothing.
    /// Also returns nil if decoding or rendering fails, which the caller treats
    /// the same way: show the unmodified frame rather than a black pane.
    static func render(
        jpeg: Data,
        adjustments: PreviewAdjustments,
        peaking: Peaking?
    ) -> NSImage? {
        guard !adjustments.isIdentity || peaking != nil else { return nil }
        guard var image = CIImage(data: jpeg) else { return nil }
        let extent = image.extent

        // 1. White balance. Correct the illuminant before anything else looks
        //    at colour, so peaking and monochrome both see corrected pixels.
        if let gains = adjustments.whiteBalance, !gains.isIdentity {
            let m = CIFilter.colorMatrix()
            m.inputImage = image
            m.rVector = CIVector(x: CGFloat(gains.red), y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: CGFloat(gains.green), z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: CGFloat(gains.blue), w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            guard let out = m.outputImage else { return nil }
            image = out
        }

        // 2. Invert, turning a negative into the positive it will become.
        //    After white balance on purpose: the film base cast belongs to the
        //    negative, so it's neutralised there and the result is inverted.
        //    Note this runs in the same unmanaged space as everything else, so
        //    it's a plain 1−c on encoded values, matching what you'd get from
        //    an invert in any image editor.
        if adjustments.invert {
            let f = CIFilter.colorInvert()
            f.inputImage = image
            guard let out = f.outputImage else { return nil }
            image = out
        }

        // 3. Monochrome. After white balance, because discarding chroma first
        //    would make the correction a no-op. Order against invert doesn't
        //    matter — desaturation is linear, so luma(1−c) == 1−luma(c).
        if adjustments.monochrome {
            let c = CIFilter.colorControls()
            c.inputImage = image
            c.saturation = 0
            guard let out = c.outputImage else { return nil }
            image = out
        }

        // 4. Peaking last, so its highlights sit on top and keep their colour
        //    even when the underlying frame has been desaturated or inverted.
        if let peaking {
            if let out = FocusPeaking.overlay(
                on: image,
                mode: peaking.mode,
                intensity: peaking.intensity,
                color: peaking.color
            ) {
                image = out
            }
        }

        guard let cg = context.createCGImage(
            image, from: extent, format: .RGBA8, colorSpace: outputColorSpace
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Average colour under the eyedropper, for click-to-set white balance.
    ///
    /// Samples the **unadjusted** frame on purpose: sampling the corrected
    /// preview would compound corrections, so a second click on the same spot
    /// would drift instead of being a no-op.
    ///
    /// This stays right when the preview is inverted, even though it looks
    /// backwards: the film base is the brightest part of a negative, so with
    /// invert on the user clicks something that *appears* dark. We read the
    /// original bright pixel underneath, which is the value the gains must be
    /// derived from.
    ///
    /// `point` is normalized and y-down in the frame's own (unrotated) space.
    static func sampleColor(
        jpeg: Data,
        atNormalized point: CGPoint
    ) -> (red: Double, green: Double, blue: Double)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return PixelSampler.averageColor(in: cg, atNormalized: point)
    }
}
