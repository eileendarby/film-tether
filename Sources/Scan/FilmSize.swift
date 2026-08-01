import Foundation
import CoreGraphics

/// A film format the scanner knows about.
///
/// `id` is **the website database's own identifier**, not a local index — it
/// goes over the REST API and into the sidecar verbatim, so it must never be
/// renumbered to suit the app's ordering.
///
/// Dimensions are the nominal *image* area in millimetres, which is what
/// auto-crop actually sees. For sheet film that's the exposed area rather than
/// the outer sheet, and for a mounted slide it's the mount's aperture rather
/// than the mount.
public struct FilmSize: Identifiable, Equatable, Codable, Sendable {
    public var id: Int
    public var name: String
    /// Short edge in mm, or nil for a format with no fixed dimensions.
    public var widthMM: Double?
    /// Long edge in mm, or nil.
    public var heightMM: Double?

    public init(id: Int, name: String, widthMM: Double? = nil, heightMM: Double? = nil) {
        self.id = id
        self.name = name
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    /// The placeholder row. Carries no dimensions, so it never participates in
    /// matching — it's what you fall back to, not something you detect.
    public var isUnknown: Bool { widthMM == nil || heightMM == nil }

    /// Long edge ÷ short edge, orientation-independent so a negative laid down
    /// either way matches the same format. Nil for `unknown`.
    public var aspectRatio: Double? {
        guard let w = widthMM, let h = heightMM, w > 0, h > 0 else { return nil }
        return max(w, h) / min(w, h)
    }

    /// Diagonal in mm — a single number standing in for overall size when
    /// comparing against a measured crop, and orientation-independent.
    public var diagonalMM: Double? {
        guard let w = widthMM, let h = heightMM else { return nil }
        return (w * w + h * h).squareRoot()
    }

    // MARK: - Catalogue

    /// Seed catalogue mirroring the website database as of 2026-07-29. This is
    /// only a starting point: the operator can edit the list in-app, so the
    /// live catalogue is persisted and this is what a fresh install begins with.
    ///
    /// Dimensions are **nominal** film sizes, used consistently rather than
    /// per-format guesses at usable image area. That consistency matters more
    /// than absolute accuracy here: the scale is calibrated from a confirmed
    /// negative using these same numbers, so a systematic few-percent difference
    /// between nominal size and actual exposed area cancels out of the
    /// comparison. Mixing conventions would be worse than either — an early
    /// draft used invented holder apertures for `4x5` and `8x10` that differed
    /// by 1%, which would have faked a distinction between two formats that in
    /// reality share an aspect ratio exactly.
    public static let seedCatalog: [FilmSize] = [
        FilmSize(id: 1,  name: "unknown"),
        FilmSize(id: 2,  name: "120mm Rollei",              widthMM: 56,    heightMM: 56),
        FilmSize(id: 3,  name: "4x5",                       widthMM: 101.6, heightMM: 127),
        FilmSize(id: 4,  name: "35mm",                      widthMM: 24,    heightMM: 36),
        FilmSize(id: 5,  name: "35mm slide",                widthMM: 24,    heightMM: 36),
        FilmSize(id: 6,  name: "8x10",                      widthMM: 203.2, heightMM: 254),
        FilmSize(id: 7,  name: "11x14",                     widthMM: 279.4, heightMM: 355.6),
        FilmSize(id: 8,  name: "6x9",                       widthMM: 56,    heightMM: 84),
        FilmSize(id: 9,  name: "5x7",                       widthMM: 127,   heightMM: 177.8),
        FilmSize(id: 10, name: "3.25x4.25 (80mm x 105mm)",  widthMM: 80,    heightMM: 105),
        FilmSize(id: 11, name: "2.25x3.25",                 widthMM: 57.15, heightMM: 82.55),
    ]

    /// Formats measurement can *never* separate, because they are the same
    /// frame: `35mm` and `35mm slide` are both 24×36mm and differ only by
    /// having a cardboard mount around them. Detection must offer the choice
    /// rather than pretending to know.
    ///
    /// Deliberately does **not** include `6x9` / `2.25x3.25`. Those are within
    /// half a percent on overall size — 56×84mm against 57.15×82.55mm — but
    /// differ by nearly 4% in aspect ratio, so a clean detection does favour one
    /// over the other. They're easily confused rather than identical, which is
    /// what the candidate list is for.
    public static let indistinguishableGroups: [[Int]] = [[4, 5]]

    /// The `unknown` row, used whenever nothing can be identified.
    public static var unknown: FilmSize {
        seedCatalog.first { $0.id == 1 } ?? FilmSize(id: 1, name: "unknown")
    }
}

/// Picks the film size that best explains a detected crop.
public enum FilmSizeMatcher {

    /// One candidate format, with how well it fits.
    public struct Match: Equatable {
        public let size: FilmSize
        /// Relative aspect-ratio error, 0 being exact. 0.02 = 2% out.
        public let aspectError: Double
        /// Relative size error, or nil when no scale is known.
        public let sizeError: Double?

        /// Combined score, lower is better. Size dominates when it's available
        /// because it's the only thing that separates the formats that share an
        /// aspect ratio.
        public var score: Double {
            guard let sizeError else { return aspectError }
            return sizeError * 2 + aspectError
        }
    }

    /// Formats whose aspect ratio is within `tolerance` of the crop's, best
    /// first. With `mmPerPixel` supplied they're additionally ranked — and
    /// separated — by actual size.
    ///
    /// **Without a scale this is genuinely ambiguous, by construction.** `4x5`
    /// and `8x10` have identical aspect ratios, as do `35mm` and `6x9`; nothing
    /// in the crop's shape can tell them apart. Callers must be prepared to
    /// show more than one candidate rather than silently taking the first.
    public static func candidates(
        forCropSize crop: CGSize,
        in catalog: [FilmSize],
        mmPerPixel: Double? = nil,
        tolerance: Double = 0.06
    ) -> [Match] {
        guard crop.width > 0, crop.height > 0 else { return [] }
        let cropAspect = Double(max(crop.width, crop.height) / min(crop.width, crop.height))
        let cropDiagonalPx = Double((crop.width * crop.width + crop.height * crop.height).squareRoot())

        var matches: [Match] = []
        for size in catalog {
            guard let aspect = size.aspectRatio, let diagonal = size.diagonalMM else { continue }
            let aspectError = abs(aspect - cropAspect) / cropAspect
            guard aspectError <= tolerance else { continue }
            var sizeError: Double?
            if let mmPerPixel, mmPerPixel > 0 {
                let measured = cropDiagonalPx * mmPerPixel
                sizeError = abs(measured - diagonal) / diagonal
            }
            matches.append(Match(size: size, aspectError: aspectError, sizeError: sizeError))
        }
        return matches.sorted {
            $0.score == $1.score ? $0.size.id < $1.size.id : $0.score < $1.score
        }
    }

    /// Best single guess, or `unknown` when nothing is close enough.
    public static func bestMatch(
        forCropSize crop: CGSize,
        in catalog: [FilmSize],
        mmPerPixel: Double? = nil,
        tolerance: Double = 0.06
    ) -> FilmSize {
        candidates(forCropSize: crop, in: catalog,
                   mmPerPixel: mmPerPixel, tolerance: tolerance).first?.size
            ?? catalog.first { $0.isUnknown } ?? FilmSize.unknown
    }

    /// Scale implied by a crop the operator has confirmed is `size`.
    ///
    /// This is the calibration step that makes absolute matching possible at
    /// all: the camera can't report its height above the copy stand, so
    /// mm-per-pixel has to be learned from one known negative. It stays valid
    /// only while the rig geometry is unchanged — moving the camera or changing
    /// the lens invalidates it.
    public static func mmPerPixel(cropSize crop: CGSize, isSize size: FilmSize) -> Double? {
        guard crop.width > 0, crop.height > 0, let diagonal = size.diagonalMM else { return nil }
        let cropDiagonalPx = Double((crop.width * crop.width + crop.height * crop.height).squareRoot())
        guard cropDiagonalPx > 0 else { return nil }
        return diagonal / cropDiagonalPx
    }
}
