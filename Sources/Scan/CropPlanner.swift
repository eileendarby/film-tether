import Foundation
import CoreGraphics

/// Decides the crop, using what the session already knows.
///
/// Detection on a single frame is treated everywhere else as if each capture
/// arrived out of nowhere. It doesn't: an operator works through a stack of the
/// same format, in the same holder, centred under the same lens. By the second
/// negative, the format and the holder's position are known to far better
/// accuracy than any single-frame detector achieves — so the detector's job
/// changes from *finding* the frame to *confirming* it.
///
/// That gives a check the detector can't give itself. `FrameRegion` returned a
/// 1.60 aspect on a 120 negative — not a slightly wrong crop but a shape no 120
/// frame can be. Nothing in the region's own evidence says so; the expectation
/// does, immediately.
///
/// When the detection is rejected, the fallback doesn't try to detect harder.
/// It builds the frame from what's known — the format's aspect ratio, the
/// holder's edges, the lens's position — and then uses detection for the one
/// thing left over: sliding it along the strip until one side meets a real edge.
/// The result isn't exact, but it is the right shape and the right size in the
/// right place, which a wrong-shaped detection never is.
public enum CropPlanner {

    public enum Route: String, Sendable {
        /// The region detector's own answer, confirmed against expectation.
        case detected
        /// Built from the expected format and the holder, then slid so one side
        /// sits on a detected edge.
        case anchored
        /// Built from the expected format and the holder, with nothing close
        /// enough to anchor to. Centred under the lens.
        case centred
    }

    public struct Plan: Sendable, Equatable {
        /// The crop, normalized [0,1]², y-down.
        public let rect: CGRect
        /// Rotation in degrees, clockwise. Zero on the fallback routes, which
        /// have no way to measure it.
        public let angle: Double
        public let route: Route
        /// The format the plan is built on, if one was expected.
        public let size: FilmSize?
        /// Which side was pinned to a detected edge, on the anchored route.
        public let anchoredEdge: CropDetector.Edge?
        /// Thresholds the region held over. Zero on the fallback routes.
        public let stableSteps: Int

        public init(rect: CGRect, angle: Double, route: Route, size: FilmSize?,
                    anchoredEdge: CropDetector.Edge?, stableSteps: Int) {
            self.rect = rect
            self.angle = angle
            self.route = route
            self.size = size
            self.anchoredEdge = anchoredEdge
            self.stableSteps = stableSteps
        }
    }

    /// How far a detected aspect ratio may sit from the expected format's before
    /// the detection is disbelieved.
    ///
    /// Generous, because a crop that clips a millimetre of rebate is still the
    /// right frame. It is not meant to catch small errors — it is meant to catch
    /// a detection that has found something else entirely, which in practice
    /// misses by tens of percent rather than by a few.
    public static let aspectTolerance = 0.08

    /// A detection contradicting the expected format is believed anyway if it
    /// held over this many thresholds *and* matches some other catalogue format
    /// closely. That's the operator changing film, which has to remain possible
    /// without them telling us first.
    public static let confidentSteps = 6

    /// How far the fallback may slide to reach an edge, as a fraction of its own
    /// length along that axis. Beyond this the edge is more likely to belong to
    /// a different frame than to this one.
    public static let maxAnchorShift = 0.4

    public static func plan(
        in image: CGImage,
        expecting: FilmSize? = nil,
        around centre: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> Plan? {
        guard let grid = ColorGrid.sample(image, width: FrameRegion.analysisWidth) else { return nil }
        return plan(in: grid, expecting: expecting, around: centre)
    }

    public static func plan(
        in grid: ColorGrid, expecting: FilmSize?, around centre: CGPoint
    ) -> Plan? {
        let detected = FrameRegion.detectBySweep(in: grid, around: centre)

        if let d = detected, accept(d, expecting: expecting, grid: grid) {
            let r = d.frame
            return Plan(
                rect: CGRect(x: r.center.x - r.size.width / 2,
                             y: r.center.y - r.size.height / 2,
                             width: r.size.width, height: r.size.height),
                angle: r.angle,
                route: .detected,
                size: expecting,
                anchoredEdge: nil,
                stableSteps: d.stableSteps
            )
        }

        // Plan B needs to know the format; without one there's nothing to build
        // from, and a bad detection is all there is.
        guard let expected = expecting, let aspect = expected.aspectRatio else {
            guard let d = detected else { return nil }
            let r = d.frame
            return Plan(
                rect: CGRect(x: r.center.x - r.size.width / 2,
                             y: r.center.y - r.size.height / 2,
                             width: r.size.width, height: r.size.height),
                angle: r.angle, route: .detected, size: nil,
                anchoredEdge: nil, stableSteps: d.stableSteps
            )
        }
        return fallback(in: grid, expected: expected, aspect: aspect, around: centre)
    }

    /// Believe the detection?
    static func accept(
        _ d: FrameRegion.SweepResult, expecting: FilmSize?, grid: ColorGrid
    ) -> Bool {
        // A region running off the picture is a lower bound on the frame, not a
        // measurement of it, so its shape means nothing.
        guard !d.frame.touchesBorder else { return false }
        guard let expected = expecting, let want = expected.aspectRatio else { return true }

        let w = d.frame.size.width * Double(grid.width)
        let h = d.frame.size.height * Double(grid.height)
        guard w > 0, h > 0 else { return false }
        let got = max(w, h) / min(w, h)
        if abs(got - want) / want <= aspectTolerance { return true }

        // Disagrees with what we expected. Believe it only if it held over a
        // long plateau *and* is a good match for some other real format — the
        // operator swapping from 120 to 4x5 should not need to announce it, but
        // a shape that is no format at all is a failure, not a change of film.
        guard d.stableSteps >= confidentSteps else { return false }
        let px = CGSize(width: w, height: h)
        guard let best = FilmSizeMatcher.candidates(
            forCropSize: px, in: FilmSize.seedCatalog, tolerance: aspectTolerance).first
        else { return false }
        return best.aspectError <= aspectTolerance
    }

    // MARK: - Plan B

    static func fallback(
        in grid: ColorGrid, expected: FilmSize, aspect: Double, around centre: CGPoint
    ) -> Plan? {
        guard let bounds = crossBounds(in: grid, around: centre) else { return nil }

        // The holder pins the film across its width, so that dimension is known
        // outright. The other follows from the format: roll film runs with its
        // long edge along the strip.
        let crossExtent = Double(bounds.far - bounds.near + 1)
        let crossPixels = bounds.axis == .horizontal ? Double(grid.height) : Double(grid.width)
        let alongPixels = bounds.axis == .horizontal ? Double(grid.width) : Double(grid.height)
        let crossNorm = crossExtent / crossPixels
        let alongNorm = (crossExtent * aspect) / alongPixels

        let crossCentre = (Double(bounds.near) + Double(bounds.far)) / 2 / crossPixels
        let alongCentre = bounds.axis == .horizontal ? centre.x : centre.y

        var alongLow = alongCentre - alongNorm / 2
        var anchoredEdge: CropDetector.Edge?

        // Slide to meet a real edge. Only one side is pinned: the other follows
        // from the format, which is known better than any second edge could be
        // measured. Pinning both would let two independent errors set the size.
        let orientation: EdgeVoting.Orientation = bounds.axis == .horizontal ? .vertical : .horizontal
        let raw = EdgeVoting.candidates(
            in: grid, orientation: orientation,
            across: bounds.near...bounds.far, minCoverage: 0.5)
        // Merged generously, and towards the centre. A band of unexposed film
        // has *two* edges — the far one where the previous frame ended and the
        // near one where this frame begins — and only the near one is this
        // frame's boundary. Merging tightly leaves both standing, and the
        // fallback then anchors to whichever happens to be nearer, which is the
        // outer one whenever the box starts slightly wide. Measured: that put
        // the crop 280 px beyond the frame's real edge.
        //
        // The radius is a rebate's width, not a frame's, so distinct frame
        // edges are never at risk of being merged with each other.
        let extent = Int(alongPixels)
        // Peak selection, not innermost. A rebate presents two faces and only
        // the inner one is this frame's edge, but which of the two is stronger
        // isn't fixed — measured on one capture, the right rebate's inner face
        // led its cluster at 0.254 against the outer's 0.159, while the left
        // rebate's outer face led. Preferring the innermost member instead lets
        // any picture detail sitting just inside a real edge displace it, which
        // it did. The radius is a rebate's width, so the pair still merges and
        // the stronger face speaks for both.
        let candidates = EdgeVoting.merged(raw, within: max(4, extent / 25))
        if !candidates.isEmpty {
            let alongHigh = alongLow + alongNorm
            var best: (shift: Double, edge: CropDetector.Edge)?
            for c in candidates {
                let at = Double(c.index) / alongPixels
                for (target, edge) in [(alongLow, lowEdge(bounds.axis)),
                                       (alongHigh, highEdge(bounds.axis))] {
                    let shift = at - target
                    guard abs(shift) <= alongNorm * maxAnchorShift else { continue }
                    if best == nil || abs(shift) < abs(best!.shift) {
                        best = (shift, edge)
                    }
                }
            }
            if let best {
                alongLow += best.shift
                anchoredEdge = best.edge
            }
        }

        let rect = bounds.axis == .horizontal
            ? CGRect(x: alongLow, y: crossCentre - crossNorm / 2,
                     width: alongNorm, height: crossNorm)
            : CGRect(x: crossCentre - crossNorm / 2, y: alongLow,
                     width: crossNorm, height: alongNorm)

        return Plan(
            rect: rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
            angle: 0,
            route: anchoredEdge == nil ? .centred : .anchored,
            size: expected,
            anchoredEdge: anchoredEdge,
            stableSteps: 0
        )
    }

    private static func lowEdge(_ axis: FilmProfile.Axis) -> CropDetector.Edge {
        axis == .horizontal ? .left : .top
    }

    private static func highEdge(_ axis: FilmProfile.Axis) -> CropDetector.Edge {
        axis == .horizontal ? .right : .bottom
    }

    // MARK: - The holder

    /// Where the exposed picture stops, across the strip.
    ///
    /// Named for what it measures rather than for what stops it. Usually that's
    /// the holder, but a frame that doesn't run to the film's edge is stopped by
    /// its own rebate first — and either way the answer is the frame's extent
    /// across the strip, which is what the fallback needs.
    public struct CrossBounds: Sendable, Equatable {
        /// The axis the *film* runs along. `.horizontal` means the strip runs
        /// left to right and the holder bounds it top and bottom.
        public let axis: FilmProfile.Axis
        /// First and last line of film, on the axis the holder bounds.
        public let near: Int, far: Int

        public init(axis: FilmProfile.Axis, near: Int, far: Int) {
            self.axis = axis
            self.near = near
            self.far = far
        }
    }

    /// How far a line's level must sit from the picture's before it counts as
    /// holder rather than film.
    ///
    /// The holder is a mask or a bare light table, so it is at one extreme or
    /// the other and nowhere near the picture — a large margin is safe and keeps
    /// a dark corner of the photograph from reading as holder.
    public static let holderDelta = 0.25

    /// Fraction of a line that must be holder before the line counts as holder.
    ///
    /// High, because the holder is opaque across its whole width while a line of
    /// film never is — but not so high that a line straddling the mask's own
    /// edge fails. Measured on a real capture, 0.9 rejected the last row at the
    /// bottom of the frame, where the black band covers most but not all of it,
    /// and the whole fallback was lost with it.
    public static let holderFraction = 0.75

    /// Find where the picture stops across the strip, and with it which way
    /// the film runs.
    ///
    /// The strip's direction is *not* inferred from the film's own shape, which
    /// is what earlier attempts did and got wrong. It's read off the holder: the
    /// axis the holder bounds is the one across the film, so the film runs along
    /// the other. That works whatever the frame's aspect ratio, including a 6×6
    /// where the frame is square and its shape says nothing at all.
    public static func crossBounds(in grid: ColorGrid, around centre: CGPoint) -> CrossBounds? {
        var block: [Double] = []
        for y in (grid.height * 3 / 8)..<(grid.height * 5 / 8) {
            for x in (grid.width * 3 / 8)..<(grid.width * 5 / 8) {
                block.append(grid[x, y].luminance)
            }
        }
        guard !block.isEmpty else { return nil }
        block.sort()
        let picture = block[block.count / 2]

        func bounds(_ axis: FilmProfile.Axis) -> (near: Int, far: Int)? {
            let count = axis == .vertical ? grid.width : grid.height
            let depth = axis == .vertical ? grid.height : grid.width
            guard count > 8, depth > 0 else { return nil }

            // A line is holder only if *nearly all* of it is, not if its average
            // says so. Averages fail here for the same reason they failed the
            // edge detectors: a row of film crosses picture and rebate together,
            // and its mean lands between them — far enough from the picture's
            // own level to be mistaken for a mask. Measured on a synthetic
            // strip, that truncated the film's extent by six rows.
            func isHolder(_ i: Int) -> Bool {
                var count = 0
                for d in 0..<depth {
                    let v = axis == .vertical ? grid[i, d].luminance : grid[d, i].luminance
                    if abs(v - picture) >= holderDelta { count += 1 }
                }
                return Double(count) / Double(depth) >= holderFraction
            }
            // Look a little way in from each border rather than demanding the
            // very first and last line. The mask's edge is not always perfectly
            // aligned with the sensor's, and one stray line at the boundary
            // shouldn't decide that this axis isn't bounded at all — measured on
            // a real capture, where insisting on line zero lost the holder
            // entirely and with it the whole fallback.
            let probe = max(2, count / 40)
            guard let firstHolder = (0..<probe).last(where: isHolder),
                  let lastHolder = ((count - probe)..<count).first(where: isHolder)
            else { return nil }
            var near = firstHolder
            while near < count, isHolder(near) { near += 1 }
            var far = lastHolder
            while far > near, isHolder(far) { far -= 1 }
            guard far > near else { return nil }
            return (near, far)
        }

        // `.horizontal` lines are rows; rows being bounded means the holder is
        // above and below, so the film runs left to right.
        if let b = bounds(.horizontal) {
            return CrossBounds(axis: .horizontal, near: b.near, far: b.far)
        }
        if let b = bounds(.vertical) {
            return CrossBounds(axis: .vertical, near: b.near, far: b.far)
        }
        return nil
    }
}
