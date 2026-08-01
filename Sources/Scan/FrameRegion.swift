import Foundation
import CoreGraphics

/// Finds the frame as a *region* rather than as a set of edges: threshold the
/// picture to the band of densities that exposed film occupies, then take the
/// connected blob the lens is pointed at.
///
/// **Why a region.** Projections and line votes both reduce the picture to one
/// dimension before deciding anything, and a boundary that is thin, or partly
/// obscured, or shared with a busy photograph, does not survive that reduction.
/// Connectivity keeps the second dimension: a frame is a contiguous area of
/// exposed film bounded on all sides by film that isn't, and that statement can
/// be tested directly.
///
/// **Why the centre and not the largest.** Threshold-and-contour implementations
/// conventionally take the largest contour, which quietly assumes one negative
/// in view. On a strip that returns several frames joined by whatever the
/// threshold let through, or the wrong frame. Growing from the point under the
/// lens returns the frame being scanned, and needs no assumption about how many
/// there are.
///
/// **Rotation comes free.** The region's minimum-area rectangle is oriented, so
/// a negative sitting a degree or two off square is measured as the rectangle it
/// is rather than as the larger upright box containing it. Nothing else here can
/// do that.
public enum FrameRegion {

    public struct Result: Sendable, Equatable {
        /// Centre of the frame, normalized [0,1]², y-down.
        public let center: CGPoint
        /// Size of the frame, normalized to the picture's dimensions.
        public let size: CGSize
        /// Rotation clockwise in degrees, positive turning the frame's top edge
        /// to the right. Small in practice — a negative on a copy stand is
        /// nearly square to the sensor.
        public let angle: Double
        /// Fraction of the picture the region covers. Very high means the
        /// threshold let everything through and the answer is meaningless.
        public let coverage: Double
        /// True if the region touches the picture's border, i.e. the negative
        /// continues past what the camera can see.
        public let touchesBorder: Bool

        /// Axis-aligned bounding box, for callers that can't use the angle yet.
        public var boundingRect: CGRect {
            let r = abs(angle) * .pi / 180
            let w = size.width * cos(r) + size.height * sin(r)
            let h = size.width * sin(r) + size.height * cos(r)
            return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        }

        public init(center: CGPoint, size: CGSize, angle: Double,
                    coverage: Double, touchesBorder: Bool) {
            self.center = center
            self.size = size
            self.angle = angle
            self.coverage = coverage
            self.touchesBorder = touchesBorder
        }
    }

    /// The band of luminance that counts as exposed film.
    ///
    /// Both bounds matter and they exclude different things. The upper one keeps
    /// out unexposed film — clear base, brighter than any exposed part of a
    /// negative. The lower one keeps out the holder and any bare light table.
    /// Without the lower bound the region leaks straight from the picture into
    /// the holder wherever the two touch with no rebate between them, which on a
    /// strip is the whole of its long edges.
    public struct Band: Sendable, Equatable {
        public let low: Double, high: Double

        public init(low: Double, high: Double) {
            self.low = min(low, high)
            self.high = max(low, high)
        }

        public func contains(_ v: Double) -> Bool { v >= low && v <= high }
    }

    /// Erosion radius, in working-grid pixels.
    ///
    /// Dust, scratches and grain survive thresholding as speckle; eroding then
    /// dilating removes anything thinner than this while leaving the frame's own
    /// shape where it was. It also breaks the one-pixel bridges that would
    /// otherwise let the region leak through a soft edge into its neighbour.
    public static let erosionRadius = 2

    /// Reject a region covering more than this fraction of the picture: the
    /// threshold has admitted everything and there is no frame to speak of.
    public static let maxCoverage = 0.92

    /// Working width. Higher than a projection method needs — connectivity is
    /// decided pixel by pixel, so a boundary only has to be one pixel thick to
    /// hold, but it does have to survive the downsample.
    public static let analysisWidth = 512

    /// Angles searched for the minimum-area rectangle, in degrees either way.
    ///
    /// Bounded deliberately. A copy stand holds the negative nearly square, so a
    /// large answer means the region is the wrong shape rather than the negative
    /// being at 40° — and searching wide would let a badly-grown region justify
    /// itself with an implausible angle.
    public static let maxAngle = 8.0
    public static let angleStep = 0.25

    public static func detect(
        in image: CGImage,
        around centre: CGPoint = CGPoint(x: 0.5, y: 0.5),
        band: Band
    ) -> Result? {
        guard let grid = ColorGrid.sample(image, width: analysisWidth) else { return nil }
        return detect(in: grid, around: centre, band: band)
    }

    public static func detect(in grid: ColorGrid, around centre: CGPoint, band: Band) -> Result? {
        var mask = [Bool](repeating: false, count: grid.width * grid.height)
        for y in 0..<grid.height {
            for x in 0..<grid.width where band.contains(grid[x, y].luminance) {
                mask[y * grid.width + x] = true
            }
        }
        return detect(mask: mask, width: grid.width, height: grid.height, around: centre)
    }

    /// Grow from a mask worked out by the caller.
    ///
    /// Separated because the *mask* is the part that's hard and the growing is
    /// the part that works. A luminance band is the obvious mask and it is
    /// enough on some negatives; on others the picture's bright areas are
    /// brighter than the unexposed film, the two populations overlap outright,
    /// and no threshold on level can separate them however it's chosen —
    /// measured, on a real capture where the picture reached 0.682 and the
    /// rebate sat at 0.65. Those need a mask built on something other than
    /// level, and can use everything below unchanged.
    public static func detect(
        mask rawMask: [Bool], width w: Int, height h: Int,
        around centre: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> Result? {
        guard w > 8, h > 8, rawMask.count == w * h else { return nil }
        let mask = opened(rawMask, width: w, height: h, radius: erosionRadius)

        // Start at the lens. If thresholding happened to reject that exact pixel
        // — a speck, a dark line — spiral out for the nearest one it kept, so a
        // single unlucky pixel doesn't cost the whole detection.
        let sx = min(max(Int(centre.x * Double(w)), 0), w - 1)
        let sy = min(max(Int(centre.y * Double(h)), 0), h - 1)
        guard let seed = nearestSet(in: mask, width: w, height: h, x: sx, y: sy) else { return nil }

        let (points, touchesBorder) = grow(mask, width: w, height: h, from: seed)
        guard points.count > 16 else { return nil }
        let coverage = Double(points.count) / Double(w * h)
        guard coverage <= maxCoverage else { return nil }

        let (centreP, sizeP, angle) = minimumAreaRect(points)
        return Result(
            center: CGPoint(x: centreP.x / Double(w), y: centreP.y / Double(h)),
            size: CGSize(width: sizeP.width / Double(w), height: sizeP.height / Double(h)),
            angle: angle,
            coverage: coverage,
            touchesBorder: touchesBorder
        )
    }

    // MARK: - Threshold sweep

    public struct SweepResult: Sendable, Equatable {
        public let frame: Result
        /// How many consecutive thresholds agreed on this rectangle. This is the
        /// confidence: it says the boundary the region stopped at survived the
        /// threshold being moved, which is what a real edge does and what a
        /// coincidence doesn't.
        public let stableSteps: Int
        /// The span of thresholds over which it held.
        public let thresholds: ClosedRange<Double>

        public init(frame: Result, stableSteps: Int, thresholds: ClosedRange<Double>) {
            self.frame = frame
            self.stableSteps = stableSteps
            self.thresholds = thresholds
        }
    }

    /// Rectangles this close together, as a fraction of the picture, count as
    /// the same answer.
    public static let stabilityTolerance = 0.02

    /// Consecutive thresholds that must agree before the answer is believed.
    public static let minStableSteps = 4

    public static let sweepStep = 0.03

    /// Working width for the *sweep*, coarser than a single detection's.
    ///
    /// The sweep runs a full detection at every step, so its cost is the single
    /// detection's multiplied by fifty-odd. What it is looking for — does the
    /// rectangle hold still — needs far less resolution than the rectangle
    /// itself, and the plateau it finds is then re-measured at full width.
    public static let sweepWidth = 256

    /// Sweep the threshold instead of choosing one, and return the rectangle
    /// that holds still.
    ///
    /// Choosing a threshold is the hard part of every region method, and it
    /// cannot be done well from the histogram alone — measured repeatedly, on
    /// negatives where the picture's own tones overlap the unexposed film's
    /// outright. Sweeping sidesteps the choice: a real frame keeps its shape
    /// while the threshold moves, because the boundary it stops at is a genuine
    /// discontinuity, and it collapses only when the threshold finally crosses
    /// that discontinuity and the region floods.
    ///
    /// The run length is returned rather than discarded, because it answers a
    /// question the rectangle alone can't: *is there a threshold answer here at
    /// all*. Measured across three captures, one showed the same rectangle over
    /// seven consecutive thresholds while two never repeated a rectangle once —
    /// on those, every threshold method is guessing, and saying so beats
    /// returning the guess.
    ///
    /// Both polarities are swept, since unexposed film reads bright on a
    /// negative and dark on a positive, and the longer plateau wins.
    public static func detectBySweep(
        in image: CGImage,
        around centre: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> SweepResult? {
        guard let grid = ColorGrid.sample(image, width: sweepWidth) else { return nil }
        return detectBySweep(in: grid, around: centre)
    }

    public static func detectBySweep(
        in grid: ColorGrid, around centre: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> SweepResult? {
        // The picture's own level, sampled where the lens is pointed, is where
        // the sweep starts: the band always contains the centre.
        var block: [Double] = []
        for y in (grid.height * 3 / 8)..<(grid.height * 5 / 8) {
            for x in (grid.width * 3 / 8)..<(grid.width * 5 / 8) {
                block.append(grid[x, y].luminance)
            }
        }
        guard !block.isEmpty else { return nil }
        block.sort()
        let picture = block[block.count / 2]

        let plateaus = sweep(grid, centre: centre, from: picture, rising: true)
            + sweep(grid, centre: centre, from: picture, rising: false)
        // Longest is not best. A region that has flooded the whole picture is
        // *also* stable — once it covers everything, moving the threshold
        // changes nothing — and it is stable over a wider span than the real
        // frame, because the real frame's plateau ends as soon as the threshold
        // crosses its boundary. Measured: on a capture whose true plateau ran
        // seven steps, a flooded one ran nineteen and won.
        //
        // A frame wholly inside the picture is the thing being looked for, so
        // those are preferred outright, and only among equals does length
        // decide.
        return plateaus.max { a, b in
            let ai = a.frame.touchesBorder ? 0 : 1, bi = b.frame.touchesBorder ? 0 : 1
            return ai == bi ? a.stableSteps < b.stableSteps : ai < bi
        }
    }

    /// Every run of agreeing thresholds, not just the longest — the caller
    /// decides which kind of stability it wants.
    private static func sweep(
        _ grid: ColorGrid, centre: CGPoint, from picture: Double, rising: Bool
    ) -> [SweepResult] {
        var samples: [(threshold: Double, result: Result?)] = []
        var t = rising ? picture + sweepStep : picture - sweepStep
        while rising ? t <= 0.99 : t >= 0.01 {
            let band = rising ? Band(low: 0, high: t) : Band(low: t, high: 1)
            samples.append((t, detect(in: grid, around: centre, band: band)))
            t += rising ? sweepStep : -sweepStep
        }

        var runs: [[(threshold: Double, result: Result)]] = []
        var run: [(threshold: Double, result: Result)] = []
        func close() {
            if run.count >= minStableSteps { runs.append(run) }
            run = []
        }
        for s in samples {
            guard let r = s.result else { close(); continue }
            if let last = run.last?.result, !agree(last, r) { close() }
            run.append((s.threshold, r))
        }
        close()

        return runs.map { r in
            let first = r.first!.threshold, last = r.last!.threshold
            return SweepResult(
                frame: median(r.map(\.result)),
                stableSteps: r.count,
                thresholds: min(first, last)...max(first, last)
            )
        }
    }

    static func agree(_ a: Result, _ b: Result) -> Bool {
        abs(a.center.x - b.center.x) <= stabilityTolerance
            && abs(a.center.y - b.center.y) <= stabilityTolerance
            && abs(a.size.width - b.size.width) <= stabilityTolerance
            && abs(a.size.height - b.size.height) <= stabilityTolerance
    }

    /// Component-wise median. The run's members are near-identical by
    /// construction, so this is a tie-break rather than an average, and a median
    /// keeps it from being pulled by the one sample at the end of the run where
    /// the region has just begun to spill.
    static func median(_ results: [Result]) -> Result {
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let cx = mid(results.map { Double($0.center.x) })
        let cy = mid(results.map { Double($0.center.y) })
        let sw = mid(results.map { Double($0.size.width) })
        let sh = mid(results.map { Double($0.size.height) })
        let angle = mid(results.map { $0.angle })
        let coverage = mid(results.map { $0.coverage })
        return Result(
            center: CGPoint(x: cx, y: cy),
            size: CGSize(width: sw, height: sh),
            angle: angle,
            coverage: coverage,
            touchesBorder: results.contains { $0.touchesBorder }
        )
    }

    // MARK: - Morphology

    /// Erode then dilate by the same radius: removes speckle and thin bridges,
    /// and puts the surviving region back at its original size.
    static func opened(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return mask }
        return dilate(erode(mask, width: w, height: h, radius: radius),
                      width: w, height: h, radius: radius)
    }

    /// Separable, so the cost is linear in the radius rather than quadratic.
    static func erode(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        morph(mask, width: w, height: h, radius: radius, keepIf: false)
    }

    static func dilate(_ mask: [Bool], width w: Int, height h: Int, radius: Int) -> [Bool] {
        morph(mask, width: w, height: h, radius: radius, keepIf: true)
    }

    /// One separable pass each way. `keepIf` true dilates (any neighbour set),
    /// false erodes (every neighbour set).
    private static func morph(
        _ mask: [Bool], width w: Int, height h: Int, radius: Int, keepIf any: Bool
    ) -> [Bool] {
        // Unsafe buffers throughout: this runs once per sweep step, over every
        // pixel, with a tap per radius — the innermost loop in the whole
        // detector. Bounds-checked indexing here cost 292 seconds across the
        // planner's tests.
        var horizontal = [Bool](repeating: false, count: w * h)
        var out = [Bool](repeating: false, count: w * h)
        mask.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { mid in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        var acc = !any
                        for d in -radius...radius {
                            let j = min(max(x + d, 0), w - 1)
                            let v = src[row + j]
                            acc = any ? (acc || v) : (acc && v)
                        }
                        mid[row + x] = acc
                    }
                }
            }
            horizontal.withUnsafeBufferPointer { mid in
                out.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        for x in 0..<w {
                            var acc = !any
                            for d in -radius...radius {
                                let i = min(max(y + d, 0), h - 1)
                                let v = mid[i * w + x]
                                acc = any ? (acc || v) : (acc && v)
                            }
                            dst[y * w + x] = acc
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Region growing

    /// Nearest masked pixel to (x, y), searched outwards in square rings.
    ///
    /// Each ring visits its perimeter only. Written as a full `(2r+1)²` block
    /// with the interior filtered out, this is quadratic per ring and cubic
    /// overall — measured at 5.3 seconds for thirteen small test cases, nearly
    /// all of it spent here on the one case where the mask is empty and every
    /// ring gets walked.
    static func nearestSet(in mask: [Bool], width w: Int, height h: Int,
                           x: Int, y: Int) -> Int? {
        if mask[y * w + x] { return y * w + x }
        func at(_ nx: Int, _ ny: Int) -> Int? {
            guard nx >= 0, nx < w, ny >= 0, ny < h, mask[ny * w + nx] else { return nil }
            return ny * w + nx
        }
        let limit = max(w, h)
        for r in 1..<limit {
            // Top and bottom edges of the ring, corners included.
            for dx in -r...r {
                if let i = at(x + dx, y - r) { return i }
                if let i = at(x + dx, y + r) { return i }
            }
            // Left and right edges, corners already covered.
            if r > 1 {
                for dy in (-r + 1)...(r - 1) {
                    if let i = at(x - r, y + dy) { return i }
                    if let i = at(x + r, y + dy) { return i }
                }
            }
        }
        return nil
    }

    /// Four-connected flood fill. Diagonal connectivity is deliberately not
    /// used: it would let a region cross a boundary that touches only at a
    /// corner, which after erosion is exactly the kind of contact left between
    /// two frames whose separator is nearly gone.
    static func grow(_ mask: [Bool], width w: Int, height h: Int,
                     from seed: Int) -> (points: [(x: Int, y: Int)], touchesBorder: Bool) {
        var seen = [Bool](repeating: false, count: w * h)
        var stack = [seed]
        seen[seed] = true
        var points: [(x: Int, y: Int)] = []
        var touchesBorder = false
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            points.append((x, y))
            if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
            // Neighbours written out rather than iterated over a literal array,
            // which is heap-allocated once per pixel. Worth avoiding on a live
            // preview frame, though measurement showed it was not where the
            // time was going — see `nearestSet`.
            func visit(_ j: Int) {
                guard mask[j], !seen[j] else { return }
                seen[j] = true
                stack.append(j)
            }
            if x > 0 { visit(i - 1) }
            if x < w - 1 { visit(i + 1) }
            if y > 0 { visit(i - w) }
            if y < h - 1 { visit(i + w) }
        }
        return (points, touchesBorder)
    }

    // MARK: - Minimum-area rectangle

    /// Smallest oriented rectangle containing the points, searched over a narrow
    /// range of angles.
    ///
    /// Run against the convex hull rather than every point, so the search is
    /// over a handful of vertices however large the region.
    static func minimumAreaRect(
        _ points: [(x: Int, y: Int)]
    ) -> (center: CGPoint, size: CGSize, angle: Double) {
        let hull = convexHull(points)
        guard hull.count >= 3 else {
            let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            return (CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                    CGSize(width: maxX - minX + 1, height: maxY - minY + 1), 0)
        }
        var best: (area: Double, centre: CGPoint, size: CGSize, angle: Double) =
            (.infinity, .zero, .zero, 0)
        var a = -maxAngle
        while a <= maxAngle {
            let r = a * .pi / 180
            let c = cos(r), s = sin(r)
            var minU = Double.infinity, maxU = -Double.infinity
            var minV = Double.infinity, maxV = -Double.infinity
            for p in hull {
                let u = p.x * c + p.y * s
                let v = -p.x * s + p.y * c
                minU = min(minU, u); maxU = max(maxU, u)
                minV = min(minV, v); maxV = max(maxV, v)
            }
            let width = maxU - minU, height = maxV - minV
            let area = width * height
            if area < best.area {
                // Rotate the centre back into the picture's own axes.
                let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
                best = (area,
                        CGPoint(x: cu * c - cv * s, y: cu * s + cv * c),
                        CGSize(width: width, height: height),
                        a)
            }
            a += angleStep
        }
        return (best.centre, best.size, best.angle)
    }

    /// Monotone chain. Returns the hull counter-clockwise.
    static func convexHull(_ points: [(x: Int, y: Int)]) -> [CGPoint] {
        guard points.count >= 3 else { return points.map { CGPoint(x: $0.x, y: $0.y) } }
        var sorted: [CGPoint] = points.map { CGPoint(x: Double($0.x), y: Double($0.y)) }
        sorted.sort { a, b in a.x == b.x ? a.y < b.y : a.x < b.x }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}
