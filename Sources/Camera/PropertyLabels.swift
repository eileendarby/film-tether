import Foundation

/// Pretty-label formatter for libgphoto2 widget values exposed by the Canon EOS 7D's
/// PTP driver. The driver returns terse strings, `"160"` for ISO, `"2.8"` for aperture,
/// `"0.005"` for a 1/200s shutter, `"AV"` for the mode dial, that are correct but ugly.
/// This file maps them to display strings a photographer would actually recognize.
///
/// All methods are pure and synchronous, call from any actor. Unknown values pass
/// through unchanged so we never *lose* information; we only beautify what we recognize.
public enum PropertyLabels {

    // MARK: - ISO

    /// `"160"` → `"ISO 160"`. Numeric values get the prefix; `"Auto"` stays `"Auto"`.
    public static func iso(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        // "Auto" and friends pass through.
        if Int(trimmed) != nil {
            return "ISO \(trimmed)"
        }
        return trimmed
    }

    // MARK: - Aperture

    /// `"2.8"` → `"f/2.8"`. Already-prefixed values pass through.
    public static func aperture(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        if trimmed.lowercased().hasPrefix("f/") || trimmed.lowercased().hasPrefix("f ") {
            return trimmed
        }
        if Double(trimmed) != nil {
            return "f/\(trimmed)"
        }
        return trimmed
    }

    // MARK: - Shutter

    /// libgphoto2's Canon driver reports shutter speed as decimal seconds:
    ///   `"30"` → 30 seconds (long), `"0.5"` → 1/2, `"0.005"` → 1/200, `"0.0001"` → 1/8000.
    /// Plus special strings: `"auto"`, `"bulb"`, `"Bulb"`.
    /// Convert to the photographer-friendly form a 7D shows on its top LCD.
    public static func shutter(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        let lower = trimmed.lowercased()
        if lower == "auto" { return "Auto" }
        if lower == "bulb" { return "Bulb" }
        // Some libgphoto2 builds report "1/200" directly, pass through.
        if trimmed.contains("/") { return trimmed }
        // Some builds report fractions like "0.005" or "1/200", handle both.
        if let s = Double(trimmed) {
            if s >= 1.0 {
                // Long exposure: integer seconds for whole values, decimal otherwise.
                if s == s.rounded() {
                    return "\(Int(s))s"
                }
                return String(format: "%.1fs", s)
            }
            // Fractional second: convert to "1/N" with N rounded to the nearest standard stop.
            let inverse = 1.0 / s
            let rounded = roundToStandardShutter(inverse)
            return "1/\(rounded)"
        }
        return trimmed
    }

    /// Round an inverse-shutter value (e.g. 199.something) to the nearest standard
    /// shutter denominator. Canon's standard ladder: 4000, 3200, 2500, 2000, 1600,
    /// 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160, 125, 100, 80, 60, 50,
    /// 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4 (third-stop increments).
    /// We round to the closest member of this set; unknown values keep their raw integer.
    private static func roundToStandardShutter(_ inverse: Double) -> Int {
        let ladder: [Int] = [
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000,
            800, 640, 500, 400, 320, 250, 200, 160, 125, 100,
            80, 60, 50, 40, 30, 25, 20, 15, 13, 10,
            8, 6, 5, 4, 3, 2,
        ]
        let candidate = ladder.min(by: { abs(Double($0) - inverse) < abs(Double($1) - inverse) })
        return candidate ?? Int(inverse.rounded())
    }

    // MARK: - White balance

    /// Canon WB mode names. libgphoto2 may report `"Auto"`, `"Daylight"`,
    /// `"Cloudy"`, `"Tungsten"`, `"Fluorescent"`, `"Flash"`, `"Custom"`,
    /// `"Color Temperature"` (the Kelvin-picker mode). We leave these as-is;
    /// they're already photographer-readable. The numeric Kelvin field is
    /// formatted by `kelvin(_:)`.
    public static func whiteBalance(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        return trimmed
    }

    /// `5600` → `"5600K"`. Already-suffixed pass through.
    public static func kelvin(_ raw: Int?) -> String {
        guard let k = raw, k > 0 else { return "—" }
        return "\(k)K"
    }

    // MARK: - Exposure mode (mode dial)

    /// Canon's mode-dial labels. libgphoto2 reports terse codes like `"M"`,
    /// `"Av"`, `"Tv"`, `"P"`, `"B"`, `"AV"`, `"TV"`, `"C1"`, `"C2"`, `"C3"`,
    /// `"A-DEP"`, `"Auto"`. Map to spelled-out names for the status bar.
    public static func exposureMode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        switch trimmed.uppercased() {
        case "M":     return "Manual (M)"
        case "AV", "AV MODE", "APERTURE PRIORITY", "APERTURE-PRIORITY":
            return "Aperture priority (Av)"
        case "TV", "TV MODE", "SHUTTER PRIORITY", "SHUTTER-PRIORITY":
            return "Shutter priority (Tv)"
        case "P":     return "Program (P)"
        case "B", "BULB":
            return "Bulb (B)"
        case "AUTO":  return "Auto"
        case "A-DEP": return "Auto-DEP"
        case "C1":    return "Custom 1 (C1)"
        case "C2":    return "Custom 2 (C2)"
        case "C3":    return "Custom 3 (C3)"
        default:      return trimmed
        }
    }

    // MARK: - Image format

    /// Canon image-format values from libgphoto2's choices on the 7D include strings
    /// like `"RAW"`, `"RAW + Large Fine JPEG"`, `"Large Fine JPEG"`, `"Small Normal JPEG"`.
    /// Pass through, they're already readable.
    public static func imageFormat(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        return trimmed
    }

    // MARK: - Battery level

    /// Some libgphoto2 builds report battery as percentage (`"75%"`), others as integer
    /// (`"75"`). Normalize to always include `%`.
    public static func battery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "—" { return trimmed }
        if trimmed.hasSuffix("%") { return trimmed }
        if Int(trimmed) != nil { return "\(trimmed)%" }
        return trimmed
    }

    // MARK: - Choices

    /// Apply the per-property label transform across a choice list. Used by ExposureBar's
    /// dropdown menus so the displayed options match the displayed current value.
    public static func transform(choices: [String], forProperty prop: String) -> [(raw: String, label: String)] {
        let formatter: (String) -> String
        switch prop {
        case "iso":           formatter = iso
        case "aperture":      formatter = aperture
        case "shutterspeed":  formatter = shutter
        case "whitebalance":  formatter = whiteBalance
        case "autoexposuremode", "expprogram": formatter = exposureMode
        case "imageformat":   formatter = imageFormat
        case "batterylevel":  formatter = battery
        default:              formatter = { $0 }
        }
        return choices.map { (raw: $0, label: formatter($0)) }
    }
}
