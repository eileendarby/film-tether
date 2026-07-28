import Foundation
import CoreGraphics

/// Per-channel multipliers applied to the preview to neutralise a colour cast.
///
/// For film scanning the cast being removed is usually the film base itself —
/// you click the unexposed leader and everything downstream is corrected
/// relative to it. Gains are the right representation (rather than a colour
/// temperature) because a film base is off-neutral on *both* axes, and a
/// Kelvin-only control can slide along blue↔amber but cannot touch
/// green↔magenta at all. The camera's own WB control is Kelvin-only, which is
/// exactly why this correction lives on the host.
public struct ChannelGains: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    /// Gains below/above this are refused. A near-black sample would otherwise
    /// divide out to an enormous multiplier and blow the preview to garbage.
    public static let minGain = 0.25
    public static let maxGain = 4.0

    /// A sample dimmer than this on every channel is treated as unusable —
    /// there isn't enough signal to say what its colour is.
    public static let minUsableLevel = 0.02

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = ChannelGains(red: 1, green: 1, blue: 1)

    public var isIdentity: Bool { self == .identity }

    /// Gains that would render the sampled colour neutral grey.
    ///
    /// The target is the sample's own mean level, so correcting preserves
    /// roughly the brightness you clicked on instead of darkening or blowing
    /// out the frame — clicking a bright film base shouldn't also be an
    /// exposure change.
    ///
    /// Returns nil when the sample is too dark to carry reliable colour, so the
    /// caller can tell the user to pick a brighter spot rather than silently
    /// applying a wild correction. Channels are expected in 0...1.
    public static func neutralizing(red r: Double, green g: Double, blue b: Double) -> ChannelGains? {
        guard r.isFinite, g.isFinite, b.isFinite else { return nil }
        guard max(r, max(g, b)) >= minUsableLevel else { return nil }
        let target = (r + g + b) / 3
        guard target > 0 else { return nil }
        return ChannelGains(
            red: clampGain(target / r),
            green: clampGain(target / g),
            blue: clampGain(target / b)
        )
    }

    /// Division by a zero or negative channel yields infinity or a nonsense
    /// sign; both collapse to the ceiling, which is the most correction we're
    /// willing to apply in one click.
    private static func clampGain(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return maxGain }
        return min(max(v, minGain), maxGain)
    }
}

/// Host-side adjustments applied to the live preview before it's displayed.
///
/// These are *view* corrections: the camera is not reconfigured and captured
/// files are never re-encoded. They're recorded per scan so the same treatment
/// can be replayed onto the RAW later, and so the colour-vs-monochrome flag can
/// be reported to the server.
public struct PreviewAdjustments: Equatable, Codable, Sendable {
    /// Render the preview as greyscale. Raw pixels off a black-and-white
    /// negative carry no meaningful colour, so showing them in colour is just
    /// noise to judge exposure and focus through.
    public var monochrome: Bool
    /// Invert tones, so a negative is previewed as the positive image it will
    /// become. Judging framing, focus and exposure on an inverted image is
    /// guesswork; this is what makes the preview show the actual photograph.
    public var invert: Bool
    /// White-balance correction, or nil for as-shot.
    ///
    /// Applied *before* inversion, which is the order film scanning wants: the
    /// film base cast is a property of the negative, so it's neutralised on the
    /// negative and the result is then inverted.
    public var whiteBalance: ChannelGains?

    public init(
        monochrome: Bool = false,
        invert: Bool = false,
        whiteBalance: ChannelGains? = nil
    ) {
        self.monochrome = monochrome
        self.invert = invert
        self.whiteBalance = whiteBalance
    }

    public static let none = PreviewAdjustments()

    /// True when nothing would change, letting the render path skip decoding
    /// and re-encoding the frame entirely. That matters at 30 fps: the common
    /// case is no adjustments at all, and it should cost nothing.
    public var isIdentity: Bool {
        !monochrome && !invert && (whiteBalance == nil || whiteBalance == .identity)
    }
}
