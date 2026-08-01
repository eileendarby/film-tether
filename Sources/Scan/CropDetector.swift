import Foundation
import CoreGraphics

/// Bounding box of everything in a preview frame that isn't the background.
///
/// This answers "is there film in view, and roughly where", which is a
/// different question from "which frame is under the lens" — that one is
/// `FrameFinder`, and it's the one auto-crop uses. This is kept for the coarse
/// check, where a single box around all the film is what's wanted.
///
/// The approach is the one `croppy` and similar tools use, and it suits a copy
/// stand well: the frame is overwhelmingly background (the light table or the
/// holder's mask) with one rectangular region that differs from it. So rather
/// than hunting for edges — which film grain, dust and sprocket holes all
/// produce in quantity — it estimates the background from the border, marks
/// every pixel unlike it, and takes the bounding box of that mask.
///
/// Working on a projection profile rather than per-pixel blobs is what makes it
/// robust to dust specks and scratches: an isolated speck contributes one count
/// to its row and column and is filtered out by the coverage threshold, while a
/// real film edge contributes a count to *every* row it spans.
public enum CropDetector {

    /// A side of the frame.
    public enum Edge: String, CaseIterable, Sendable {
        case left, right, top, bottom
    }

    public struct Result: Equatable, Sendable {
        /// Detected rectangle in normalized [0,1]² coordinates, y-down, in the
        /// frame's own orientation.
        public let rect: CGRect
        /// Fraction of sampled pixels that differed from the background. Very
        /// low means almost nothing was found, very high means the background
        /// estimate failed and nearly everything looked like content.
        public let coverage: Double
        /// Sides where content runs right up to the frame edge, so no boundary
        /// was found there and the negative continues beyond what the camera
        /// can see.
        ///
        /// This is the difference between "the negative is this shape" and "the
        /// negative is at least this big". Observed on the copy stand with a 120
        /// negative framed too tightly: the film's own top and bottom edges were
        /// found correctly while it ran off both sides, and without this the
        /// result looked like a confident full-width crop.
        public let unboundedEdges: Set<Edge>

        /// True when a boundary was found on all four sides, i.e. the whole
        /// negative is inside the frame. Only then is the crop trustworthy as a
        /// measurement of the negative's size.
        public var isFullyBounded: Bool { unboundedEdges.isEmpty }

        public init(rect: CGRect, coverage: Double, unboundedEdges: Set<Edge> = []) {
            self.rect = rect
            self.coverage = coverage
            self.unboundedEdges = unboundedEdges
        }
    }

    /// Width the frame is reduced to before analysis. The negative's edges are a
    /// large-scale feature, so there's nothing to gain from full resolution and
    /// a great deal of speed to lose — this runs against a live preview.
    public static let analysisWidth = 256

    /// How far a pixel must differ from the background to count as content,
    /// on a 0...1 luminance scale. Low enough to catch a dense, dark negative
    /// against a dark mask; high enough to ignore sensor noise and vignetting.
    public static let defaultThreshold = 0.10

    /// A row or column must have at least this fraction of its pixels marked
    /// before it's considered part of the negative. This is the dust filter.
    public static let defaultCoverage = 0.20

    /// A detected rectangle spanning at least this fraction of the frame in
    /// *both* axes is rejected.
    ///
    /// Filling the frame edge to edge means no boundary was found on any side,
    /// which is what happens when there's no negative in view (or it's so
    /// tightly framed there's nothing to crop to) — the border ring is then part
    /// of the subject, the background estimate is meaningless, and the honest
    /// answer is "I can't see a negative" rather than a confident full-frame
    /// rect. Measured against the live preview with nothing on the copy stand:
    /// 93.5% coverage and a rect covering the whole frame, reported as a clean
    /// detection.
    ///
    /// A negative running off *one* edge still detects, because it stays bounded
    /// on the opposite side and so remains under this in at least one axis.
    public static let maxSpan = 0.98

    /// Detect the negative's rectangle, or nil if nothing convincing is found.
    ///
    /// - Parameters:
    ///   - image: the preview frame.
    ///   - threshold: luminance difference that counts as content.
    ///   - minCoverage: fraction of a row/column that must be content.
    ///   - marginFraction: how much to grow the result on each side, as a
    ///     fraction of the frame. A little breathing room around the negative
    ///     is wanted so the crop doesn't shave the edge of the image.
    public static func detect(
        in image: CGImage,
        threshold: Double = defaultThreshold,
        minCoverage: Double = defaultCoverage,
        marginFraction: Double = 0
    ) -> Result? {
        guard let sample = luminanceGrid(of: image) else { return nil }
        let w = sample.width, h = sample.height
        guard w > 2, h > 2 else { return nil }

        // Background = median of the border ring. Median rather than mean so a
        // negative that runs off the edge of the frame — or a bright speck on
        // the mask — doesn't drag the estimate toward the content.
        var border: [Double] = []
        border.reserveCapacity(2 * (w + h))
        for x in 0..<w {
            border.append(sample[x, 0])
            border.append(sample[x, h - 1])
        }
        for y in 0..<h {
            border.append(sample[0, y])
            border.append(sample[w - 1, y])
        }
        border.sort()
        let background = border[border.count / 2]

        // Mark content, accumulating per-row and per-column counts in one pass.
        var rowCounts = [Int](repeating: 0, count: h)
        var colCounts = [Int](repeating: 0, count: w)
        var marked = 0
        for y in 0..<h {
            for x in 0..<w where abs(sample[x, y] - background) > threshold {
                rowCounts[y] += 1
                colCounts[x] += 1
                marked += 1
            }
        }
        let coverage = Double(marked) / Double(w * h)
        guard marked > 0 else { return nil }

        guard let (top, bottom) = span(rowCounts, of: w, minCoverage: minCoverage),
              let (left, right) = span(colCounts, of: h, minCoverage: minCoverage)
        else { return nil }

        // Half-open on the far edge: a span covering columns 3...7 occupies the
        // area from 3 to 8, so the rect's width is 5 columns, not 4.
        var rect = CGRect(
            x: Double(left) / Double(w),
            y: Double(top) / Double(h),
            width: Double(right - left + 1) / Double(w),
            height: Double(bottom - top + 1) / Double(h)
        )
        // Which sides, if any, had no boundary. Recorded before the margin is
        // applied, since growing the rect would push it to the edges anyway.
        var unbounded: Set<Edge> = []
        if left == 0 { unbounded.insert(.left) }
        if right == w - 1 { unbounded.insert(.right) }
        if top == 0 { unbounded.insert(.top) }
        if bottom == h - 1 { unbounded.insert(.bottom) }

        // No boundary anywhere — see `maxSpan`. Reject rather than returning the
        // whole frame dressed up as a detection.
        guard unbounded.count < Edge.allCases.count else { return nil }
        if marginFraction > 0 {
            rect = rect.insetBy(dx: -marginFraction, dy: -marginFraction)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Result(rect: rect, coverage: coverage, unboundedEdges: unbounded)
    }

    /// First and last index whose count clears the coverage threshold.
    private static func span(
        _ counts: [Int], of extent: Int, minCoverage: Double
    ) -> (Int, Int)? {
        let needed = Int((Double(extent) * minCoverage).rounded(.up))
        guard let first = counts.firstIndex(where: { $0 >= needed }),
              let last = counts.lastIndex(where: { $0 >= needed })
        else { return nil }
        return (first, last)
    }

    // MARK: - Sampling

    /// Downsampled luminance grid, indexed `[x, y]` top-down.
    struct Grid {
        let width: Int
        let height: Int
        private let values: [Double]

        init(width: Int, height: Int, values: [Double]) {
            self.width = width
            self.height = height
            self.values = values
        }

        subscript(x: Int, y: Int) -> Double { values[y * width + x] }
    }

    /// Render the image small and grey, in sRGB so the luminance figures mean
    /// the same thing they do to `PixelSampler`.
    static func luminanceGrid(of image: CGImage) -> Grid? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        let w = min(analysisWidth, srcW)
        let h = max(1, Int((Double(srcH) / Double(srcW) * Double(w)).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium   // averages, so specks shrink
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var values = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(bytes[i * 4]) / 255
            let g = Double(bytes[i * 4 + 1]) / 255
            let b = Double(bytes[i * 4 + 2]) / 255
            values[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return Grid(width: w, height: h, values: values)
    }
}
