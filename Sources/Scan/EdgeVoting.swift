import Foundation
import CoreGraphics

/// Finds the straight edges of a negative by letting every row vote on where
/// they are.
///
/// **Why voting rather than line averages.** Averaging a whole column and asking
/// whether it looks like unexposed film only works when the boundary is a *band*
/// — a wide inter-frame gap. It fails on the commoner case of a frame edge that
/// is a thin **density step**: averaged over the full height, a step a few pixels
/// wide competes with everything the photograph is doing and disappears.
/// Measured on a real 120 strip, an edge plainly visible at x=609 of 8192 was
/// invisible to the line-average detector, which reported that side as having no
/// boundary at all.
///
/// A step is local, so it should be looked for locally. Each row is examined on
/// its own for sudden shifts in density; each shift is one short piece of
/// evidence for an edge at that x. Picture detail produces plenty of shifts too,
/// but they land wherever the picture happens to put them, while a film edge
/// lands at the *same x in every row it crosses*. Accumulating the votes lets
/// hundreds of weak, independent observations outvote strong but unaligned ones.
///
/// This is also why the thresholds can be per-row and generous: a row is asked
/// only for its own most abrupt transitions, not for anything on an absolute
/// scale, so nothing has to be calibrated against the exposure or the film
/// stock. The alignment does the discriminating.
public enum EdgeVoting {

    /// One candidate edge.
    public struct Candidate: Sendable, Equatable {
        /// Column index for a vertical edge, row index for a horizontal one.
        public let index: Int
        /// How many lines voted for it.
        public let votes: Int
        /// Votes as a fraction of the lines that could have voted. This is the
        /// "enough segments align" test: a real edge is crossed by most of the
        /// lines that meet it.
        public let coverage: Double
        /// Mean size of the density shift at this edge, 0...1. Ranks two
        /// candidates that are equally well aligned.
        public let strength: Double

        public init(index: Int, votes: Int, coverage: Double, strength: Double) {
            self.index = index
            self.votes = votes
            self.coverage = coverage
            self.strength = strength
        }
    }

    /// Which way a candidate edge runs.
    public enum Orientation: String, Sendable {
        /// A vertical edge, found from horizontal density shifts; `index` is a
        /// column.
        case vertical
        /// A horizontal edge, found from vertical density shifts; `index` is a
        /// row.
        case horizontal
    }

    /// A shift must exceed the line's median by this many median-absolute
    /// deviations to be worth a vote.
    ///
    /// Robust statistics, per line, so a busy row and a plain one are each judged
    /// against their own behaviour. Set low on purpose: a vote is cheap and only
    /// alignment makes it count, so it costs little to let a marginal step
    /// through and a great deal to reject a real one.
    public static let voteThresholdMADs = 3.0

    /// Votes are pooled across this many neighbouring lines.
    ///
    /// The negative is never perfectly square to the sensor. Over a thousand
    /// rows even a fraction of a degree of rotation walks an edge sideways by
    /// more than a pixel, which would otherwise split one edge's votes across
    /// several columns and leave none of them looking convincing.
    public static let alignmentTolerance = 1

    /// Fraction of lines that must agree before a candidate is returned.
    public static let minCoverage = 0.25

    /// Rank the candidate edges of one orientation, best first.
    ///
    /// - Parameters:
    ///   - grid: the picture.
    ///   - orientation: which way the edges run.
    ///   - range: restrict the *crossing* lines to this span — rows for a
    ///     vertical edge. Used to look only where the film is.
    /// A narrow band of density to look across, as a fraction of the 0...1
    /// luminance scale.
    ///
    /// Everything below the band is flattened to black and everything above it
    /// to white, so the only gradients left are transitions that *cross* the
    /// band. Put the band between the picture's tones and the film base's and
    /// the frame edge is one of the few things in the picture that still has an
    /// edge at all — which is what makes the alignment vote decisive instead of
    /// merely suggestive.
    ///
    /// This matters because a photograph can be full of long straight lines of
    /// its own: an interior with shelves and doorframes produces vertical edges
    /// that align across hundreds of rows just as convincingly as the film's
    /// does. Judged on raw luminance those outvote the real edge. Judged across
    /// a band containing only the film base transition, they aren't edges at
    /// all.
    public struct DensityWindow: Sendable, Equatable {
        public let low: Double, high: Double

        public init(low: Double, high: Double) {
            self.low = min(low, high)
            self.high = max(low, high)
        }

        /// Straddle `level`, spanning `width` in total.
        public init(around level: Double, width: Double) {
            self.init(low: level - width / 2, high: level + width / 2)
        }

        func apply(_ v: Double) -> Double {
            guard high > low else { return v }
            return min(max((v - low) / (high - low), 0), 1)
        }
    }

    public static func candidates(
        in grid: ColorGrid,
        orientation: Orientation,
        across range: ClosedRange<Int>? = nil,
        window: DensityWindow? = nil,
        minCoverage: Double = minCoverage
    ) -> [Candidate] {
        // `along` indexes the edge's position, `across` indexes the lines that
        // cross it and get a vote each.
        let along = orientation == .vertical ? grid.width : grid.height
        let acrossCount = orientation == .vertical ? grid.height : grid.width
        let span = range ?? 0...(acrossCount - 1)
        let lo = max(0, span.lowerBound), hi = min(acrossCount - 1, span.upperBound)
        guard along > 4, hi > lo else { return [] }

        func value(_ a: Int, _ c: Int) -> Double {
            let v = orientation == .vertical ? grid[a, c].luminance : grid[c, a].luminance
            return window?.apply(v) ?? v
        }

        var votes = [Int](repeating: 0, count: along)
        var strength = [Double](repeating: 0, count: along)
        var shifts = [Double](repeating: 0, count: along)

        for c in lo...hi {
            // Central difference: the size of the density shift at each step
            // along the line.
            for a in 1..<(along - 1) {
                shifts[a] = abs(value(a + 1, c) - value(a - 1, c))
            }
            shifts[0] = 0
            shifts[along - 1] = 0

            let (median, mad) = medianAndMAD(shifts)
            // A flat line has mad == 0; without a floor every one of its pixels
            // would clear the threshold and vote.
            let cutoff = median + voteThresholdMADs * max(mad, 1e-4)

            for a in 1..<(along - 1) where shifts[a] > cutoff {
                // Only the peak of a shift votes, so one soft edge spread over
                // three pixels doesn't cast three votes at three positions.
                guard shifts[a] >= shifts[a - 1], shifts[a] >= shifts[a + 1] else { continue }
                votes[a] += 1
                strength[a] += shifts[a]
            }
        }

        // Pool neighbours, then keep only the local peak of each pooled cluster
        // so one edge yields one candidate rather than a run of them.
        let possible = Double(hi - lo + 1)
        var pooled = [Int](repeating: 0, count: along)
        var pooledStrength = [Double](repeating: 0, count: along)
        for a in 0..<along {
            for d in -alignmentTolerance...alignmentTolerance {
                let j = a + d
                guard j >= 0, j < along else { continue }
                pooled[a] += votes[j]
                pooledStrength[a] += strength[j]
            }
        }

        var result: [Candidate] = []
        for a in 0..<along {
            // Capped: pooling sums the neighbours' votes, so a thick edge can
            // gather more votes than there are lines to cast them.
            let coverage = min(1, Double(pooled[a]) / possible)
            guard coverage >= minCoverage else { continue }
            // Peak of its cluster; ties break toward the lower index.
            let before = a > 0 ? pooled[a - 1] : -1
            let after = a < along - 1 ? pooled[a + 1] : -1
            guard pooled[a] > before, pooled[a] >= after else { continue }
            result.append(Candidate(
                index: a, votes: pooled[a], coverage: coverage,
                strength: pooledStrength[a] / Double(max(pooled[a], 1))
            ))
        }
        return result.sorted { ($0.coverage, $0.strength) > ($1.coverage, $1.strength) }
    }

    /// Collapse runs of neighbouring candidates into one each.
    ///
    /// A real boundary is not one line. A rebate has two edges of its own, the
    /// transition is softened by downsampling, and a negative that isn't quite
    /// square spreads each edge further still — so one boundary arrives as a
    /// cluster of five or ten candidates, all with similar agreement. Measured
    /// on a levelled capture, the right-hand frame edge came back as columns
    /// 738 through 773.
    ///
    /// Left unmerged, a cluster crowds out everything else in a ranking, and any
    /// rule that picks "the best few" returns several views of the same edge
    /// instead of the several different edges it was asked for.
    ///
    /// Pass `nearest` — normally the centre of the picture, under the lens — to
    /// keep each cluster's *innermost* member. That is the one the crop wants:
    /// unexposed film between two frames has two boundaries, the far one where
    /// the previous frame ends and the near one where this frame begins, and
    /// only the near one is this frame's edge. Measured on a levelled capture,
    /// keeping the strongest member instead put the left edge at x=456 where the
    /// frame actually starts at 609 — it had locked onto the outer boundary of
    /// the rebate, 153 px too far out.
    ///
    /// Without `nearest`, the strongest member is kept, which is the right
    /// choice when clusters come from a soft single edge rather than a band.
    public static func merged(
        _ candidates: [Candidate], within radius: Int, nearest: Int? = nil
    ) -> [Candidate] {
        guard !candidates.isEmpty else { return [] }
        // Clustered around peaks rather than by single linkage. Linkage chains:
        // where candidates are dense — a photograph with fine repeating detail —
        // each is within the radius of the next and the whole axis collapses
        // into one cluster. Measured on a textured test frame, twenty-four
        // candidates spanning columns 23 to 199 merged into a single cluster
        // whose representative, 118, was nowhere near any real edge.
        //
        // Taking the strongest candidate first and absorbing only what lies
        // within one radius of *it* bounds every cluster to the width of a real
        // boundary, however crowded its surroundings.
        var remaining = candidates.sorted { $0.strength > $1.strength }
        var result: [Candidate] = []
        while let peak = remaining.first {
            let cluster = remaining.filter { abs($0.index - peak.index) <= radius }
            remaining.removeAll { abs($0.index - peak.index) <= radius }
            guard let nearest else {
                result.append(peak)
                continue
            }
            // Position from the innermost member, score from the peak. The
            // cluster is one boundary seen several times over: unexposed film
            // between two frames has a far edge where the previous frame ended
            // and a near one where this frame begins, and only the near one is
            // this frame's. Scoring by the innermost instead buried the real
            // frame edges under picture detail.
            let inner = cluster.min { a, b in
                let da = abs(a.index - nearest), db = abs(b.index - nearest)
                return da == db ? a.strength > b.strength : da < db
            } ?? peak
            result.append(Candidate(index: inner.index, votes: peak.votes,
                                    coverage: peak.coverage, strength: peak.strength))
        }
        return result.sorted { $0.index < $1.index }
    }

    /// Median and median absolute deviation, the robust pair. A mean and a
    /// standard deviation would both be dragged around by the very shifts being
    /// looked for.
    static func medianAndMAD(_ values: [Double]) -> (median: Double, mad: Double) {
        guard !values.isEmpty else { return (0, 0) }
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        var deviations = values.map { abs($0 - median) }
        deviations.sort()
        return (median, deviations[deviations.count / 2])
    }
}
