import Foundation
import CoreGraphics

/// Finds the one negative frame under the lens, by starting at the centre and
/// walking outwards until it runs into unexposed film.
///
/// **Why centre-out.** What's on the copy stand is either a single sheet or a
/// strip of frames, and in the strip case a bounding box of "everything that
/// isn't background" spans several frames at once. The frame that matters is
/// the one under the lens, so the search starts from the centre of the image and
/// stops at the first boundary it meets in each direction. That gets the right
/// frame by construction rather than by picking one afterwards.
///
/// **What the boundary looks like.** Film that was never exposed carries no
/// picture, so it is *smooth*: neighbouring pixels along a line through it barely
/// differ. That is the signal used, and it's a better one than brightness, which
/// is what the obvious implementations key on:
///
/// - Brightness alone can't tell unexposed film from a blown-out sky or a black
///   shadow inside the picture, and it moves with every exposure change.
/// - Variance alone can't either: a line crossing a smooth gradient — a sky, a
///   wall, the light table's own falloff — has a large spread while containing
///   no detail at all.
/// - Mean neighbour-to-neighbour difference sees only *local* change, so a
///   gradient scores near zero on it and picture detail scores high, regardless
///   of exposure.
///
/// Measured on a 120 strip on the real copy stand, per column: picture
/// 0.029–0.074, unexposed rebate 0.0124–0.0141, the holder beyond the film
/// 0.0002–0.0013. Two clear gaps, and the ordering doesn't depend on whether the
/// film reads dark or light.
///
/// Smoothness is still paired with a level test, because a frame containing a
/// large featureless area could otherwise present a smooth line in the middle of
/// the picture. Unexposed film is not merely smooth, it is smooth *and* well away
/// from the picture's typical level — clear base on a negative, dense on a
/// reversal — so requiring both keeps a blank sky from reading as a frame edge.
public enum FrameFinder {

    /// What stopped the walk on one side.
    public enum Boundary: String, Sendable {
        /// Ran into unexposed film. This is a real frame edge.
        case unexposedFilm
        /// Reached the edge of the picture still inside the frame: the negative
        /// continues past what the camera can see, so the frame is bigger than
        /// what was found.
        case imageBorder
    }

    public struct Side: Sendable, Equatable {
        /// Index of the last line still belonging to the frame.
        public let index: Int
        public let boundary: Boundary
        /// Mean level of the unexposed band that stopped the walk, if one did.
        /// The film base reads at the same level all the way along a strip, so
        /// comparing this between sides is a way to check a boundary is the film
        /// itself rather than something laid over it.
        public let bandLevel: Double?

        public init(index: Int, boundary: Boundary, bandLevel: Double? = nil) {
            self.index = index
            self.boundary = boundary
            self.bandLevel = bandLevel
        }
    }

    public struct Result: Sendable, Equatable {
        /// The frame, normalized [0,1]², y-down, in the image's own orientation.
        public let rect: CGRect
        /// Sides where the negative ran past the edge of the picture.
        public let unboundedEdges: Set<CropDetector.Edge>
        /// Level of the unexposed film found around the frame, averaged over
        /// whichever sides found some. Nil if no side did.
        public let filmBaseLevel: Double?

        /// True when all four sides ended at unexposed film, so the rectangle is
        /// the whole frame and can be trusted as a measurement of its size.
        public var isFullyBounded: Bool { unboundedEdges.isEmpty }

        public init(rect: CGRect, unboundedEdges: Set<CropDetector.Edge>,
                    filmBaseLevel: Double?) {
            self.rect = rect
            self.unboundedEdges = unboundedEdges
            self.filmBaseLevel = filmBaseLevel
        }
    }

    /// Width the image is reduced to before analysis.
    ///
    /// Large enough to resolve an inter-frame gap — on a 120 strip filling the
    /// preview those run 2–3 lines at this width — and small enough that
    /// downsampling averages away grain and dust, which would otherwise look
    /// like texture on film that carries none.
    public static let analysisWidth = 192

    /// A line counts as smooth when its roughness is below this fraction of the
    /// image's median roughness.
    ///
    /// Relative, not absolute, so it moves with the exposure and the film stock.
    /// Measured: the ceiling lands at 0.017 on the reference strip, against
    /// unexposed film at most 0.0141 and picture content at least 0.0288 — clear
    /// of both by a comfortable margin.
    public static let smoothFraction = 0.5

    /// How far a smooth line must sit from the picture's level before it counts
    /// as unexposed film, on a 0...1 scale.
    ///
    /// Absolute difference, so it holds for reversal film where the unexposed
    /// band is dark rather than clear. Measured across four captures: real
    /// bands sit 0.07–0.37 from the picture.
    ///
    /// This test does less work than the step test below, but it is not
    /// redundant — measured. Dropping it and relying on the step alone still
    /// passes every unit test and both 120 strips, and then reports a confident
    /// crop on a negative that fills the whole picture with no film edges
    /// anywhere. The two tests fail differently, which is the point of having
    /// both.
    public static let minLevelDelta = 0.08

    /// Smallest run of smooth lines that counts as a boundary rather than noise,
    /// as a fraction of the line count.
    public static let minBandFraction = 0.008

    /// How far the band's level must jump from the picture line it abuts.
    ///
    /// This is the test that separates a frame edge from a smooth patch *inside*
    /// the picture, and it's the one that matters — smoothness and level alone
    /// both pass things they shouldn't. Exposed and unexposed film meet at a hard
    /// boundary; that discontinuity is what makes the edge visible in the first
    /// place. A featureless region of the photograph, by contrast, blends into
    /// its surroundings however smooth and however bright it is.
    ///
    /// Measured on the reference strip, band level against the picture line it
    /// abuts: a smooth bright wall inside the photograph stepped 0.023, while the
    /// two real inter-frame gaps stepped 0.31 and 0.17 and the film's own edge
    /// against the holder stepped 0.39. This threshold sits between them with
    /// room on both sides.
    public static let minLevelStep = 0.06

    /// Find the frame around `centre`.
    ///
    /// - Parameters:
    ///   - image: the preview frame.
    ///   - centre: where to start, normalized and y-down. Defaults to the middle
    ///     of the picture, which on a copy stand is the point under the lens.
    ///   - marginFraction: breathing room added on each side afterwards, as a
    ///     fraction of the image, so the crop doesn't shave the picture's edge.
    public static func detect(
        in image: CGImage,
        around centre: CGPoint = CGPoint(x: 0.5, y: 0.5),
        marginFraction: Double = 0
    ) -> Result? {
        guard let grid = ColorGrid.sample(image, width: analysisWidth) else { return nil }
        return detect(in: grid, around: centre, marginFraction: marginFraction)
    }

    static func detect(
        in grid: ColorGrid, around centre: CGPoint, marginFraction: Double
    ) -> Result? {
        let w = grid.width, h = grid.height
        guard w > 8, h > 8 else { return nil }
        let cx = clamp(Int((centre.x * Double(w)).rounded(.down)), 0, w - 1)
        let cy = clamp(Int((centre.y * Double(h)).rounded(.down)), 0, h - 1)

        // The two axes are measured over each other's extent, because a column
        // measured over the full height averages the film together with whatever
        // surrounds it — and the surround is usually the brightest or darkest
        // thing in view, which would swamp the film's own levels.
        //
        // That's circular, so it's bootstrapped: start with a band around the
        // centre, which is inside the frame by assumption, then re-measure each
        // axis over what the other one found.
        let seedBand = max(1, h / 4)
        var rows = clamp(cy - seedBand, 0, h - 1)...clamp(cy + seedBand, 0, h - 1)

        var columnSides = walkBothWays(
            FilmProfile.build(from: grid, axis: .vertical, across: rows), from: cx)
        guard var (left, right) = columnSides else { return nil }

        var rowSides = walkBothWays(
            FilmProfile.build(from: grid, axis: .horizontal,
                              across: left.index...right.index), from: cy)
        guard var (top, bottom) = rowSides else { return nil }

        // One refinement pass. The seed band was a guess; now that the frame's
        // vertical extent is known, the columns can be measured over exactly it.
        rows = top.index...bottom.index
        columnSides = walkBothWays(
            FilmProfile.build(from: grid, axis: .vertical, across: rows), from: cx)
        if let refined = columnSides {
            (left, right) = refined
            rowSides = walkBothWays(
                FilmProfile.build(from: grid, axis: .horizontal,
                                  across: left.index...right.index), from: cy)
            if let refinedRows = rowSides { (top, bottom) = refinedRows }
        }

        var unbounded: Set<CropDetector.Edge> = []
        if left.boundary == .imageBorder { unbounded.insert(.left) }
        if right.boundary == .imageBorder { unbounded.insert(.right) }
        if top.boundary == .imageBorder { unbounded.insert(.top) }
        if bottom.boundary == .imageBorder { unbounded.insert(.bottom) }

        // Nothing bounded on any side is not a detection — it's a picture with
        // no film in it, or film framed so tightly none of its edges show.
        guard unbounded.count < 4 else { return nil }

        let levels = [left, right, top, bottom].compactMap(\.bandLevel)
        var rect = CGRect(
            x: Double(left.index) / Double(w),
            y: Double(top.index) / Double(h),
            // Half-open on the far side: lines 3...7 occupy 3 up to 8.
            width: Double(right.index - left.index + 1) / Double(w),
            height: Double(bottom.index - top.index + 1) / Double(h)
        )
        if marginFraction > 0 {
            rect = rect.insetBy(dx: -marginFraction, dy: -marginFraction)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Result(
            rect: rect,
            unboundedEdges: unbounded,
            filmBaseLevel: levels.isEmpty ? nil : levels.reduce(0, +) / Double(levels.count)
        )
    }

    // MARK: - The walk

    /// How much of the profile, around the starting point, is taken as a sample
    /// of the picture itself.
    ///
    /// Both thresholds are relative to what the *picture* looks like, so that
    /// reference has to be measured somewhere known to be picture — and the only
    /// place known to be picture is where the walk starts, which is under the
    /// lens. Taking it from the whole profile instead is wrong whenever the
    /// unexposed film occupies a large share of the view: with a single sheet
    /// surrounded by film the profile median *is* the band level, the level test
    /// then measures the band against itself, and no edge is ever found.
    public static let referenceWindowFraction = 0.125

    /// Walk out from `start` in both directions, returning the near and far
    /// sides. Nil when the picture around the start carries no texture at all —
    /// there's nothing to tell exposed film from unexposed.
    public static func walkBothWays(_ profile: FilmProfile, from start: Int) -> (Side, Side)? {
        guard profile.count > 2 else { return nil }
        let from = clamp(start, 0, profile.count - 1)
        let minRun = max(1, Int((Double(profile.count) * minBandFraction).rounded(.up)))

        func run(_ ref: Reference) -> (Side, Side)? {
            guard ref.roughness > 1e-6 else { return nil }
            let ceiling = ref.roughness * smoothFraction
            func isUnexposed(_ i: Int) -> Bool { ref.judgesUnexposed(profile[i], ceiling: ceiling) }
            return (walk(profile, from: from, step: -1, isUnexposed: isUnexposed, minRun: minRun),
                    walk(profile, from: from, step: +1, isUnexposed: isUnexposed, minRun: minRun))
        }

        // The reference comes from a window around the start, which is inside
        // the picture by assumption. Re-measuring it afterwards over the extent
        // the walk found was tried and made things worse on real captures: once
        // a side has run off the picture, "the extent the walk found" includes
        // whatever is out there, and feeding that back in loses the edges the
        // first pass had right.
        let seed = max(4, Int(Double(profile.count) * referenceWindowFraction / 2))
        return run(reference(profile, over:
            clamp(from - seed, 0, profile.count - 1)...clamp(from + seed, 0, profile.count - 1)))
    }

    /// What the picture looks like, and the judgement that follows from it.
    struct Reference {
        let roughness: Double
        let level: Double

        /// Unexposed film is smooth, and it is well away from the picture's own
        /// level — clear base on a negative, dense on a reversal.
        func judgesUnexposed(_ line: FilmProfile.Line, ceiling: Double) -> Bool {
            return line.roughness <= ceiling
                && abs(line.level - level) >= minLevelDelta
        }
    }


    /// Measure the picture over `range`.
    static func reference(_ profile: FilmProfile, over range: ClosedRange<Int>) -> Reference {
        let lo = clamp(range.lowerBound, 0, profile.count - 1)
        let hi = clamp(range.upperBound, 0, profile.count - 1)
        guard hi >= lo else { return Reference(roughness: 0, level: 0) }
        let window = Array(profile.lines[lo...hi])
        let levels = window.map(\.level).sorted()
        return Reference(
            roughness: window.map(\.roughness).sorted()[window.count / 2],
            level: levels[window.count / 2]
        )
    }

    /// Step outward until a run of unexposed lines is found that also steps away
    /// from the picture it abuts.
    ///
    /// The run requirement stops a single stray line — a scratch, a compression
    /// artefact, one dark line of a picture — from cutting the frame short. The
    /// step requirement stops a *smooth region of the photograph* from doing the
    /// same, which is the failure the run length can't catch. The frame's edge is
    /// the line before the run starts.
    ///
    /// A run that fails either test is walked straight through rather than
    /// treated as the end, so a frame containing a featureless patch is still
    /// measured to its real edge.
    private static func walk(
        _ profile: FilmProfile, from: Int, step: Int,
        isUnexposed: (Int) -> Bool, minRun: Int
    ) -> Side {
        let limit = step < 0 ? 0 : profile.count - 1
        var i = from
        while i != limit {
            let next = i + step
            if isUnexposed(next) {
                // Measure the step against the *start* of the run, not its
                // whole length. A picture that fades gradually into the rebate
                // is one continuous smooth run, and averaging over all of it
                // would borrow the rebate's brightness to justify stopping at
                // the near end of the fade — cutting the frame short at exactly
                // the boundary this test exists to get right.
                var sum = 0.0, run = 0, leading = 0.0
                var j = next
                while j >= 0, j < profile.count, isUnexposed(j) {
                    sum += profile[j].level
                    run += 1
                    if run <= minRun { leading = sum / Double(run) }
                    j += step
                }
                if run >= minRun, abs(leading - profile[i].level) >= minLevelStep {
                    return Side(index: i, boundary: .unexposedFilm, bandLevel: leading)
                }
            }
            i = next
        }
        return Side(index: limit, boundary: .imageBorder)
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(v, lo), hi)
    }

    // MARK: - Diagnostics

    /// Explain a walk line by line: the thresholds in force and, for the lines
    /// nearest the decision, whether each test passed.
    ///
    /// Reading this against a real negative is the only way to set the
    /// thresholds honestly — the populations it has to separate depend on the
    /// film stock, the light table and the exposure, none of which can be
    /// reasoned about from here.
    public static func describeWalk(
        _ profile: FilmProfile, from start: Int, window: Int = 12
    ) -> String {
        guard profile.count > 2 else { return "  (profile too short)" }
        let seed = max(4, Int(Double(profile.count) * referenceWindowFraction / 2))
        let ref = reference(profile, over:
            clamp(start - seed, 0, profile.count - 1)...clamp(start + seed, 0, profile.count - 1))
        let ceiling = ref.roughness * smoothFraction
        let minRun = max(1, Int((Double(profile.count) * minBandFraction).rounded(.up)))
        var out = String(
            format: "  picture roughness %.4f → ceiling %.4f;  picture level %.3f → needs |Δ| ≥ %.2f and step ≥ %.2f;  min run %d\n",
            ref.roughness, ceiling, ref.level, minLevelDelta, minLevelStep, minRun)
        guard let (near, far) = walkBothWays(profile, from: start) else {
            return out + "  (no usable texture)"
        }
        out += "  near side: index \(near.index) via \(near.boundary.rawValue)\n"
        out += "  far  side: index \(far.index) via \(far.boundary.rawValue)\n"
        out += "   idx  level  rough   smooth  offLevel\n"
        for edge in [near.index, far.index] {
            for i in max(0, edge - window)...min(profile.count - 1, edge + window) {
                let l = profile[i]
                let smooth = l.roughness <= ceiling
                let off = abs(l.level - ref.level) >= minLevelDelta
                out += String(format: "  %4d  %.3f  %.4f  %@  %@%@\n",
                              i, l.level, l.roughness,
                              smooth ? "  yes " : "  no  ",
                              off ? "  yes " : "  no  ",
                              i == edge ? "   ← edge" : "")
            }
            out += "  ---\n"
        }
        return out
    }
}
