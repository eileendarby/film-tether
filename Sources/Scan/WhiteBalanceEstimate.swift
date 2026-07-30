import Foundation

/// Turns a sampled colour into a camera colour temperature.
///
/// The eyedropper's host-side gains fix the *preview*, but the file the camera
/// writes is unaffected — so a scan session balanced only on the host still
/// produces RAWs carrying the full cast. This is the other half: it works out
/// what to set the body's own white balance to, so the captures come out right.
///
/// **The model.** Under Wien's approximation a blackbody's radiance ratio at two
/// wavelengths goes as `exp(c/T)`, so the red-over-blue ratio of a neutral
/// surface, photographed with the body white-balanced for `T₀`, is
///
///     R/B = exp(c · (1/T_actual − 1/T₀))
///
/// which rearranges to the correction below. The useful property is that the
/// measurement is *relative* to the current setting: whatever the film base,
/// the picture style or the sensor's own response contribute, they contribute
/// the same offset each time and cancel out of the difference.
///
/// `responseConstant` is not the textbook Wien value (≈7993 K for 450/600 nm),
/// and it is not close to it. The camera does not hand us radiance — it hands us
/// a rendered JPEG, through a tone curve and a saturation boost, in a colour
/// space of its choosing, and that rendering makes the response to a change in
/// temperature considerably *stronger* than physics alone predicts. The constant
/// here was measured on the real body with the `wb-probe` debug command, which
/// sweeps `colortemperature` across its whole range under live view and fits
/// `ln(R/B)` against `1/T`. Taking the textbook number instead would overshoot
/// every click by about two thirds.
public enum WhiteBalanceEstimate {

    /// The body's supported range and granularity (Canon R5: 76 choices,
    /// 2500–10000 in hundreds).
    public static let minKelvin = 2500
    public static let maxKelvin = 10000
    public static let stepKelvin = 100

    /// Slope of `ln(R/B)` against `1/T`, in kelvin. Measured, not derived — see
    /// the note above.
    ///
    /// Canon R5, 2026-07-30, seven points from 2500 K to 10000 K: slope
    /// −13272.8 K, R² = 0.9954. The sign is dropped here because the formula
    /// below adds the correction rather than subtracting it.
    public static let responseConstant = 13272.8

    /// A sample this dark on every channel carries no reliable colour.
    public static let minUsableLevel = ChannelGains.minUsableLevel

    /// The colour temperature that would render the sampled colour neutral.
    ///
    /// `red`/`green`/`blue` are the encoded (gamma) sRGB channels the sampler
    /// reads, in 0...1; they're linearised here because the model is about
    /// light, not about display code values. `currentKelvin` is what the body
    /// is set to *now* — the estimate is a correction to it, so a wrong or
    /// stale value moves the answer.
    ///
    /// Returns nil when the sample is too dark, or when either the red or blue
    /// channel is empty enough to make the ratio meaningless.
    ///
    /// The result is clamped to the body's range and snapped to its step, so it
    /// is always a value the camera will actually accept.
    public static func kelvin(
        fromRed red: Double, green: Double, blue: Double, currentKelvin: Int
    ) -> Int? {
        guard red.isFinite, green.isFinite, blue.isFinite else { return nil }
        guard max(red, max(green, blue)) >= minUsableLevel else { return nil }
        let r = linearize(red), b = linearize(blue)
        guard r > 0, b > 0 else { return nil }
        guard currentKelvin > 0 else { return nil }

        let inverse = 1.0 / Double(currentKelvin) + log(r / b) / responseConstant
        // A sample far enough off neutral can invert this, which has no physical
        // meaning — it just says the correction is bigger than the range allows,
        // so take the end of the range it's heading for.
        guard inverse > 0 else { return maxKelvin }
        return snap(1.0 / inverse)
    }

    /// Clamp to the body's range and round to its step.
    public static func snap(_ kelvin: Double) -> Int {
        guard kelvin.isFinite else { return minKelvin }
        let stepped = (kelvin / Double(stepKelvin)).rounded() * Double(stepKelvin)
        return min(max(Int(stepped), minKelvin), maxKelvin)
    }

    /// The part of the cast the camera *can't* fix, left for the host.
    ///
    /// A colour temperature slides along blue↔amber and does nothing at all on
    /// green↔magenta, which is the axis a film base is most awkward on. Handing
    /// the body the temperature and keeping only the green correction here means
    /// the two aren't both correcting the same axis and fighting each other —
    /// which is what a full `ChannelGains` alongside a camera-side change would
    /// do, ending up twice as far as either intended.
    ///
    /// Red and blue are therefore left at unity and green is moved to their
    /// geometric mean; the whole thing is then renormalised so overall
    /// brightness is unchanged.
    ///
    /// Returns nil when the sample is unusable, or when there's no meaningful
    /// green cast to correct.
    public static func tintGains(
        red: Double, green: Double, blue: Double
    ) -> ChannelGains? {
        guard red.isFinite, green.isFinite, blue.isFinite else { return nil }
        guard max(red, max(green, blue)) >= minUsableLevel else { return nil }
        guard red > 0, green > 0, blue > 0 else { return nil }

        let neutral = (red * blue).squareRoot()
        let g = neutral / green
        // Preserve brightness: the mean of the three gains stays at 1.
        let norm = 3.0 / (1.0 + 1.0 + g)
        let gains = ChannelGains(red: norm, green: g * norm, blue: norm)
        return gains.isIdentity ? nil : gains
    }

    /// sRGB's encoded-to-linear transfer function.
    public static func linearize(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}
