import Foundation
import CoreGraphics

/// Per-line statistics for one axis of a frame, and the raw material for
/// finding where a negative starts and stops.
///
/// The detector works on *lines* — whole rows or whole columns — rather than
/// pixels, because every boundary it looks for spans the frame: the gap between
/// two exposed frames is a band right across the film, and the film's own edge
/// is a straight line down it. A dust speck or a scratch occupies one pixel of
/// one line and disappears into that line's average; a real edge moves every
/// line it touches.
public struct FilmProfile: Sendable {

    /// One line's summary.
    public struct Line: Sendable {
        /// Mean luminance, 0...1.
        public let level: Double
        /// Standard deviation of luminance along the line. Low means the line
        /// carries no picture.
        public let deviation: Double
        /// Mean absolute difference between neighbouring pixels along the line.
        ///
        /// This is the better texture measure of the two, and the reason both
        /// are kept. `deviation` is a *global* spread, so a line crossing a
        /// smooth gradient — a sky, a wall, a light falloff — scores high on it
        /// while carrying no detail at all. Neighbour differences see only local
        /// change, so a gradient scores near zero on this and unexposed film
        /// scores near zero on both, while real picture content scores high on
        /// this one.
        public let roughness: Double
        /// Mean colour along the line, for matching against the film base.
        public let red: Double, green: Double, blue: Double
    }

    public let lines: [Line]
    /// The axis these lines were cut along. `.vertical` lines are columns.
    public let axis: Axis

    public enum Axis: String, Sendable {
        /// Lines are columns; the index runs left to right.
        case vertical
        /// Lines are rows; the index runs top to bottom.
        case horizontal
    }

    public var count: Int { lines.count }
    public subscript(i: Int) -> Line { lines[i] }

    public init(lines: [Line], axis: Axis) {
        self.lines = lines
        self.axis = axis
    }

    // MARK: - Building

    /// Cut `grid` into lines along `axis`, restricted to `range` on the other
    /// axis.
    ///
    /// The restriction matters: measuring a column over the full height of the
    /// frame would average the film together with whatever surrounds it, and the
    /// surround is usually the brightest or darkest thing in view. Once the
    /// film's extent across one axis is known, the other axis is measured only
    /// within it.
    public static func build(
        from grid: ColorGrid, axis: Axis, across range: ClosedRange<Int>? = nil
    ) -> FilmProfile {
        let count = axis == .vertical ? grid.width : grid.height
        let depth = axis == .vertical ? grid.height : grid.width
        let span = range ?? 0...(depth - 1)
        let lo = max(0, span.lowerBound), hi = min(depth - 1, span.upperBound)
        guard count > 0, hi >= lo else { return FilmProfile(lines: [], axis: axis) }

        var lines: [Line] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            var sum = 0.0, sumSq = 0.0, rough = 0.0
            var r = 0.0, g = 0.0, b = 0.0
            var previous: Double?
            for d in lo...hi {
                let px = axis == .vertical ? grid[i, d] : grid[d, i]
                let v = px.luminance
                sum += v
                sumSq += v * v
                if let previous { rough += abs(v - previous) }
                previous = v
                r += px.red; g += px.green; b += px.blue
            }
            let n = Double(hi - lo + 1)
            let mean = sum / n
            lines.append(Line(
                level: mean,
                deviation: max(0, sumSq / n - mean * mean).squareRoot(),
                roughness: n > 1 ? rough / (n - 1) : 0,
                red: r / n, green: g / n, blue: b / n
            ))
        }
        return FilmProfile(lines: lines, axis: axis)
    }

    // MARK: - Robust summaries

    /// Median of a statistic over the lines, used as the "typical" value to
    /// judge individual lines against. Median rather than mean throughout: a
    /// mean is dragged around by the very lines being looked for.
    public func median(_ key: (Line) -> Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        return lines.map(key).sorted()[lines.count / 2]
    }

    /// Value at a quantile, 0...1.
    public func quantile(_ q: Double, _ key: (Line) -> Double) -> Double {
        guard !lines.isEmpty else { return 0 }
        let sorted = lines.map(key).sorted()
        let i = Int((Double(sorted.count - 1) * min(max(q, 0), 1)).rounded())
        return sorted[i]
    }
}

/// A small RGB image, indexed `[x, y]` top-down, in sRGB.
public struct ColorGrid: Sendable {
    public struct Pixel: Sendable {
        public let red: Double, green: Double, blue: Double
        /// Rec. 709 luma, matching the rest of the app.
        public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
    }

    public let width: Int
    public let height: Int
    private let pixels: [Pixel]

    public init(width: Int, height: Int, pixels: [Pixel]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> Pixel { pixels[y * width + x] }

    /// Render `image` small, in sRGB so the numbers agree with `PixelSampler`.
    ///
    /// Downsampling is not just for speed: averaging removes film grain and dust,
    /// which are exactly the high-frequency signals that would otherwise make
    /// unexposed film look textured.
    public static func sample(_ image: CGImage, width targetWidth: Int) -> ColorGrid? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0, targetWidth > 0 else { return nil }
        let w = min(targetWidth, srcW)
        let h = max(1, Int((Double(srcH) / Double(srcW) * Double(w)).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var pixels: [Pixel] = []
        pixels.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            pixels.append(Pixel(
                red: Double(bytes[i * 4]) / 255,
                green: Double(bytes[i * 4 + 1]) / 255,
                blue: Double(bytes[i * 4 + 2]) / 255
            ))
        }
        return ColorGrid(width: w, height: h, pixels: pixels)
    }
}
