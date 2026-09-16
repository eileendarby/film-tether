import Foundation

/// What the operator did to a frame, sent with its scan — the API's
/// "Capture attributes". The archive applies `rotate`, `flop`, `crop` and
/// `straighten` when it builds derivatives, and keeps the rest whole.
///
/// The order the archive applies them in, which is what gives the numbers
/// their meaning: straighten (about the crop box's centre) → crop (in the
/// file's own pixels, as the camera wrote it) → flop → rotate.
///
/// Encoded with the client's snake_case encoder: `whiteBalance` goes over
/// the wire as `white_balance`, `imageFormat` as `image_format`.
public struct CaptureAttributes: Codable, Equatable, Sendable {
    public struct Normalized: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public struct Crop: Codable, Equatable, Sendable {
        /// Always "file": the stored file's own pixels, unrotated, y-down.
        public var space: String
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
        /// Degrees clockwise about the box's centre, applied before the cut.
        public var straighten: Double
        /// The same box as fractions of the file — what the archive stores,
        /// since it still describes the same piece of film after a rescan.
        public var normalized: Normalized
        /// Film size id; must agree with the asset's own.
        public var format: Int?
        /// auto | manual | previous
        public var source: String

        public init(x: Int, y: Int, width: Int, height: Int, straighten: Double,
                    normalized: Normalized, format: Int?, source: String) {
            space = "file"
            self.x = x; self.y = y; self.width = width; self.height = height
            self.straighten = straighten
            self.normalized = normalized
            self.format = format
            self.source = source
        }
    }

    public struct Gains: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    public struct WhiteBalance: Codable, Equatable, Sendable {
        /// Sent to the camera; in the RAW's metadata too.
        public var kelvin: Int?
        /// Host-side multipliers on linear RGB — the green/magenta half a
        /// Kelvin control can't express. Recorded, not applied, by the archive.
        public var gains: Gains?
        /// Where the film base was clicked, file pixels.
        public var sampled: Point?
        public init(kelvin: Int?, gains: Gains?, sampled: Point?) {
            self.kelvin = kelvin; self.gains = gains; self.sampled = sampled
        }
    }

    public struct Film: Codable, Equatable, Sendable {
        public var monochrome: Bool
        public init(monochrome: Bool) { self.monochrome = monochrome }
    }

    public struct Camera: Codable, Equatable, Sendable {
        public var body: String?
        public var lens: String?
        public var iso: String?
        public var shutter: String?
        public var aperture: String?
        public var imageFormat: String?
        public init(body: String?, lens: String?, iso: String?, shutter: String?, aperture: String?, imageFormat: String?) {
            self.body = body; self.lens = lens; self.iso = iso
            self.shutter = shutter; self.aperture = aperture; self.imageFormat = imageFormat
        }
    }

    public struct Software: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public var build: String
        public init(name: String, version: String, build: String) {
            self.name = name; self.version = version; self.build = build
        }
    }

    /// 0, 90, 180 or 270: degrees clockwise to display upright.
    public var rotate: Int
    /// Mirror left to right — the strip was scanned emulsion-down. (ImageMagick's
    /// `-flop`; its `-flip` is top-to-bottom, which is `flop` + 180 here.)
    public var flop: Bool
    public var crop: Crop?
    public var whiteBalance: WhiteBalance?
    public var film: Film
    public var camera: Camera?
    public var software: Software

    public init(rotate: Int, flop: Bool, crop: Crop?, whiteBalance: WhiteBalance?,
                film: Film, camera: Camera?, software: Software) {
        self.rotate = rotate
        self.flop = flop
        self.crop = crop
        self.whiteBalance = whiteBalance
        self.film = film
        self.camera = camera
        self.software = software
    }

    public static let validRotations: Set<Int> = [0, 90, 180, 270]

    /// The image format to report: what the interface shows, unless the files
    /// the capture produced say otherwise — a RAW alone under a label that
    /// promises a JPEG, or the reverse — in which case the files win, since
    /// they are what was actually scanned.
    public static func imageFormat(interface: String, fileExtensions: [String]) -> String {
        let rawKinds: Set<String> = ["cr2", "cr3", "crw", "dng", "nef", "arw", "raf", "orf", "rw2"]
        let exts = fileExtensions.map { $0.lowercased() }
        let hasRaw = exts.contains { rawKinds.contains($0) }
        let hasJPEG = exts.contains { $0 == "jpg" || $0 == "jpeg" }
        let label = interface.trimmingCharacters(in: .whitespaces)
        let labelHasPlus = label.contains("+")
        let labelIsJPEGOnly = !labelHasPlus && label.uppercased().contains("JPEG") || (!labelHasPlus && label.hasPrefix("L") && !label.uppercased().contains("RAW"))
        switch (hasRaw, hasJPEG) {
        case (true, true):  return labelHasPlus ? label : "RAW + JPEG"
        case (true, false): return (labelHasPlus || labelIsJPEGOnly || label.isEmpty) ? "RAW" : label
        case (false, true): return (labelHasPlus || label.uppercased().contains("RAW") || label.isEmpty) ? "JPEG" : label
        case (false, false): return label
        }
    }

    /// How far to inset a box on every side, in pixels, before it is
    /// straightened by `degrees`: the corners of a box turned about its
    /// centre sweep out by about half its width times the sine of the
    /// angle, and a box drawn to the edge of the straightened picture would
    /// otherwise cut into the wedge of nothing the turn leaves behind. The
    /// archive copes with such a box; the scanner shouldn't send one.
    public static func straighteningInset(halfWidth: Double, degrees: Double) -> Int {
        guard degrees != 0, halfWidth > 0 else { return 0 }
        return Int((halfWidth * abs(sin(degrees * .pi / 180))).rounded(.up))
    }

    /// A copy the archive will accept. Attributes are checked before a
    /// transfer is registered and a refusal is a `422` for the whole send,
    /// so anything the archive would refuse is put right here instead: an
    /// odd rotation becomes 0, the straightening is held to ±45°, and a box
    /// that runs off the edge — by a pixel or two, after the pivot
    /// correction — is pulled back inside rather than dropped.
    public func validated() -> CaptureAttributes {
        var a = self
        if !Self.validRotations.contains(a.rotate) { a.rotate = 0 }
        if var c = a.crop {
            c.straighten = min(45, max(-45, c.straighten))
            var n = c.normalized
            n.width = min(max(n.width, 0), 1)
            n.height = min(max(n.height, 0), 1)
            n.x = min(max(n.x, 0), 1 - n.width)
            n.y = min(max(n.y, 0), 1 - n.height)
            c.normalized = n
            a.crop = (n.width > 0 && n.height > 0) ? c : nil
        }
        return a
    }
}
