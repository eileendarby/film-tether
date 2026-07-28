import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Host-side focus peaking for the live-view stream.
///
/// Two modes are exposed:
///   • `.edges`, classic Sobel-style edge detection (CIEdges). Catches strong
///     boundaries (faces, building lines, leaves). Cheap and forgiving but
///     under-emphasizes film grain when scanning negatives.
///   • `.grain`, high-pass via Gaussian-blur subtract. Tuned to 1-3 px
///     features so it lights up film grain *before* it lights up larger
///     structure. The goal is for peaking to point out grain before anything
///     else, since the grain should be in focus before anything else is.
///
/// Cost on an Intel Mac: edges ~10-25ms / grain ~15-30ms per 1056×704 frame.
/// Caller toggles the mode and color via AppModel; we lazily build filters
/// per call (CI graph is JIT-compiled and cached internally).
enum FocusPeaking {

    /// Eight high-contrast palette options. Cycle via Cmd-Shift-P; bound to
    /// AppModel.focusPeakingColor and persisted via AppSettings. Defaults skip
    /// dichromat-ambiguous mixes (yellow vs green, magenta vs red) to remain
    /// usable for partially colorblind users.
    enum PeakColor: String, CaseIterable, Codable {
        case cyan
        case magenta
        case yellow
        case white
        case lime
        case hotPink   = "hot-pink"
        case azure     = "azure"
        case orange

        /// Human-readable label for the Settings swatch grid.
        var displayName: String {
            switch self {
            case .cyan:     return "Cyan"
            case .magenta:  return "Magenta"
            case .yellow:   return "Yellow"
            case .white:    return "White"
            case .lime:     return "Lime"
            case .hotPink:  return "Hot pink"
            case .azure:    return "Azure"
            case .orange:   return "Orange"
            }
        }

        /// SwiftUI `Color`-style RGB tuple for the swatch fill (0..1).
        var swatchRGB: (r: Double, g: Double, b: Double) {
            switch self {
            case .cyan:     return (0,    1,    1)
            case .magenta:  return (1,    0,    1)
            case .yellow:   return (1,    1,    0)
            case .white:    return (1,    1,    1)
            case .lime:     return (0.5,  1,    0)
            case .hotPink:  return (1,    0.2,  0.6)
            case .azure:    return (0.1,  0.6,  1)
            case .orange:   return (1,    0.55, 0)
            }
        }

        /// (r, g, b) channel amplifications for ColorMatrix. Edges/grain
        /// pipelines return grayscale; the amplifier picks how each channel
        /// fills in from the gray. Tuned so each color stays vivid even when
        /// composited over a bright preview.
        var amplifiers: (r: CGFloat, g: CGFloat, b: CGFloat) {
            switch self {
            case .cyan:     return (0, 4, 4)
            case .magenta:  return (4, 0, 4)
            case .yellow:   return (4, 4, 0)
            case .white:    return (4, 4, 4)
            case .lime:     return (1, 4, 0)
            case .hotPink:  return (4, 1, 2)
            case .azure:    return (0, 2, 4)
            case .orange:   return (4, 2, 0)
            }
        }
    }

    /// What kind of high-frequency content to highlight.
    enum Mode: String, CaseIterable, Codable {
        /// CIEdges, Sobel-like operator. Good general-purpose.
        case edges
        /// Gaussian-blur subtract, band-pass tuned for 1-3 px features.
        /// Highlights film grain before larger structure.
        case grain

        var displayName: String {
            switch self {
            case .edges: return "Edges (general)"
            case .grain: return "Grain (film scanning)"
            }
        }
    }

    /// Composite peaking highlights over `inputCI` and return the result.
    /// Returns nil if the filter graph fails; the caller then shows the
    /// unpeaked frame rather than nothing.
    ///
    /// Works at the `CIImage` level rather than JPEG-to-JPEG so it can be one
    /// stage of `PreviewPipeline` — the frame is decoded once for all the
    /// host-side adjustments together instead of once per effect.
    ///
    /// `intensity` controls sensitivity. 1.0 = obvious edges only; 3.0+
    /// picks up subtle texture (film grain, fine fabric, pixel-scale noise).
    ///
    /// **Default mode is `.edges`**, the known-good working configuration.
    /// `.grain` is opt-in via Settings → Live View; tuned
    /// conservatively (lower alpha multiplier) so it lights up actual grain
    /// instead of solid-tinting flat regions.
    static func overlay(
        on inputCI: CIImage,
        mode: Mode = .edges,
        intensity: Float = 3.0,
        color: PeakColor = .cyan
    ) -> CIImage? {
        let highFreq: CIImage?
        switch mode {
        case .edges: highFreq = edgesImage(inputCI, intensity: intensity)
        case .grain: highFreq = grainImage(inputCI, intensity: intensity)
        }
        guard let highFreq else { return nil }

        // Tint the high-frequency image. Both pipelines emit grayscale where
        // bright = strong feature. ColorMatrix amplifies each channel from
        // the gray; aVector multiplier sets how aggressively weak features
        // bleed through. Edges produces hard near-binary output (Sobel
        // threshold is steep) so a high aVector (3,3,3) preserves
        // edge sharpness. Grain output is softer + noisier so we use a
        // lower aVector to keep flat regions transparent.
        let amps = color.amplifiers
        let aGain: CGFloat = (mode == .grain) ? 1.0 : 3.0
        let tint = CIFilter.colorMatrix()
        tint.inputImage = highFreq
        tint.rVector = CIVector(x: amps.r, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0, y: amps.g, z: 0, w: 0)
        tint.bVector = CIVector(x: 0, y: 0, z: amps.b, w: 0)
        tint.aVector = CIVector(x: aGain, y: aGain, z: aGain, w: 0)
        tint.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard let tinted = tint.outputImage else { return nil }

        // Composite tinted high-freq over the original frame.
        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = tinted
        composite.backgroundImage = inputCI
        return composite.outputImage?.cropped(to: inputCI.extent)
    }

    private static func edgesImage(_ input: CIImage, intensity: Float) -> CIImage? {
        let f = CIFilter.edges()
        f.inputImage = input
        f.intensity = intensity
        return f.outputImage
    }

    /// High-pass filter optimized for the spatial frequency of film grain
    /// (roughly 1-3 pixels in a 7D EVF preview at 1056×704).
    ///
    /// Pipeline:
    ///   1. Gaussian blur (radius 1.5) kills features < ~1-2 pixels.
    ///   2. `differenceBlendMode(input, blurred)` = |input - blurred|,     ///      the MAGNITUDE of high-frequency residue. Flat regions → near 0;
    ///      grain peaks → moderate; sharp edges → strong.
    ///   3. Linear gain `intensity` via ColorMatrix multiplies the residue so
    ///      subtle grain rises above noise floor.
    ///
    /// **Important: no contrast/colorMonochrome step.** A prior version used
    /// CIColorControls.contrast=4.5 which pushed everything to extremes
    /// (peaking shows an almost entirely white view instead of discrete points)
    /// because the post-difference residue is already small + noisy in the
    /// 7D LV preview. The cleaner pipeline relies on the downstream tint's
    /// alpha gain (kept low for `.grain` in apply()) to threshold weak
    /// residue into transparency, instead of trying to threshold here.
    private static func grainImage(_ input: CIImage, intensity: Float) -> CIImage? {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input
        blur.radius = 1.5
        guard let blurred = blur.outputImage?.cropped(to: input.extent) else { return nil }

        // |input - blurred| via difference blend (NOT subtract, subtract
        // returns max(0, A-B), losing half the magnitude).
        let diff = CIFilter.differenceBlendMode()
        diff.inputImage = input
        diff.backgroundImage = blurred
        guard let residue = diff.outputImage else { return nil }

        // Multiply each channel by intensity gain. Pure amplification; no
        // bias means flat regions stay near black, residue scales upward.
        // Clamping handled implicitly by downstream ColorMatrix; weak residue
        // ends up below the alpha-threshold in apply() and goes transparent.
        let gain = CGFloat(intensity)
        let amp = CIFilter.colorMatrix()
        amp.inputImage = residue
        amp.rVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        amp.gVector = CIVector(x: 0, y: gain, z: 0, w: 0)
        amp.bVector = CIVector(x: 0, y: 0, z: gain, w: 0)
        amp.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        amp.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return amp.outputImage
    }
}
