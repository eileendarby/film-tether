import Foundation
import CoreGraphics
import ImageIO
import CGPhoto2

/// Controls the camera's digital sensor-crop zoom for live view (the "punch-in" feature
/// equivalent to pressing the magnifier button on the camera body).
///
/// Some 2009-era EOS bodies, including the original 7D, historically silent-no-op the
/// `eoszoom` write while returning OK status. `probeZoomSupported` detects this; if it
/// returns false, the App layer falls back to client-side JPEG-crop zoom of the preview frames.
@CameraActor
public final class LiveZoom {
    public enum Mode: Int, Sendable {
        case fit = 1
        case fivex = 5
        // .tenx removed, empirically the 7D's eoszoom widget silent-no-ops
        // (or clamps) at 10× on this firmware. 10× does not work on this body,
        // so it was removed. 5× is the only working punch-in factor.
    }

    private let session: CameraSession

    public init(session: CameraSession) {
        self.session = session
    }

    public func setZoom(_ mode: Mode) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "eoszoom"
        )
        defer { gp_widget_unref(root) }
        let t = WidgetHelpers.widgetType(leaf)
        if t == GP_WIDGET_RADIO || t == GP_WIDGET_MENU {
            // Log the enum choices the first time we see this widget so we
            // know what zoom factors the 7D's libgphoto2 driver actually
            // supports. 5x and 10x look identical, suggesting the body
            // silently clamps 10 → 5 (or the widget enum only
            // exposes "1" and "5").
            let choices = (try? WidgetHelpers.choices(leaf)) ?? []
            if !choices.isEmpty {
                CameraLog.liveZoom.info("eoszoom choices: \(choices.joined(separator: ", "), privacy: .public)")
            }
            try WidgetHelpers.writeString(leaf, value: "\(mode.rawValue)")
        } else if t == GP_WIDGET_TEXT {
            try WidgetHelpers.writeString(leaf, value: "\(mode.rawValue)")
        } else if t == GP_WIDGET_RANGE {
            try WidgetHelpers.writeFloat(leaf, value: Float(mode.rawValue))
        } else if t == GP_WIDGET_TOGGLE {
            try WidgetHelpers.writeToggle(leaf, value: Int32(mode.rawValue))
        } else {
            throw CameraError.widgetTypeMismatch(
                expected: "TEXT/RADIO/MENU/RANGE/TOGGLE",
                got: WidgetHelpers.typeName(t)
            )
        }
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "eoszoom", leaf: leaf)
        CameraLog.liveZoom.info("setZoom(\(mode.rawValue, privacy: .public)) committed (widget type=\(WidgetHelpers.typeName(t), privacy: .public))")
    }

    /// Position the zoom rect within the frame. Coordinates are camera-frame pixels;
    /// the camera ignores out-of-bounds writes.
    public func setZoomPosition(x: Int, y: Int) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "eoszoomposition"
        )
        defer { gp_widget_unref(root) }
        try WidgetHelpers.writeString(leaf, value: "\(x),\(y)")
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "eoszoomposition", leaf: leaf)
    }

    /// Probe whether camera-side `eoszoom` actually punches in (some 7D firmwares silent-no-op).
    /// Returns true if the centers of the baseline (fit) and zoomed (5x) frames differ enough
    /// to confirm the sensor crop took effect.
    ///
    /// The two closures fetch one preview JPEG each, typically wired to `LiveView.fetchOnePreview`.
    /// Restores fit zoom at the end.
    public func probeZoomSupported(
        captureBaseline: @Sendable () async throws -> Data,
        captureZoomed: @Sendable () async throws -> Data
    ) async throws -> Bool {
        try await setZoom(.fit)
        // Allow camera to render the fit frame before sampling.
        try? await Task.sleep(nanoseconds: 250_000_000)
        let baseline = try await captureBaseline()

        // Defer restoration BEFORE we commit the 5x zoom so the camera doesn't get stuck
        // there if captureZoomed throws.
        defer { Task { try? await self.setZoom(.fit) } }

        try await setZoom(.fivex)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let zoomed = try await captureZoomed()

        let diff = Self.meanCenterPixelDifference(baseline: baseline, zoomed: zoomed)
        return diff > 8.0
    }

    /// Mean absolute pixel difference between the 100×100 center crops of two JPEGs,
    /// computed in grayscale (luminance). Public + static for testability.
    public static func meanCenterPixelDifference(baseline: Data, zoomed: Data) -> Double {
        guard let baselineLum = decodeCenterLuminance(baseline, size: 100),
              let zoomedLum = decodeCenterLuminance(zoomed, size: 100),
              baselineLum.count == zoomedLum.count, !baselineLum.isEmpty else {
            return 0
        }
        var total: Double = 0
        for i in 0..<baselineLum.count {
            total += Double(abs(Int(baselineLum[i]) - Int(zoomedLum[i])))
        }
        return total / Double(baselineLum.count)
    }

    private static func decodeCenterLuminance(_ jpeg: Data, size: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let w = img.width, h = img.height
        guard w >= size, h >= size else { return nil }
        let cropX = (w - size) / 2
        let cropY = (h - size) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: size, height: size)
        guard let cropped = img.cropping(to: cropRect) else { return nil }

        var bytes = [UInt8](repeating: 0, count: size * size)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &bytes,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))
        return bytes
    }
}

/// Convenience: a pure-Foundation JPEG-crop fallback used by the App layer when the
/// probe above returns false. Crops a centered rect of the JPEG and returns a new
/// JPEG sized to the original frame's dimensions for drop-in display.
public enum JPEGCrop {
    /// Returns a JPEG cropped to a `1/divisor` rect of the source, centered
    /// at the normalized `center` point (0..1 in each axis). divisor=5 →
    /// crop is 1/5 × 1/5 of the source. Returns nil on decode failure.
    /// The crop is clamped so it always lies entirely inside the source.
    public static func cropAt(_ jpeg: Data, divisor: Int, center: CGPoint) -> Data? {
        guard divisor > 1 else { return jpeg }
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let w = img.width, h = img.height
        let cropW = w / divisor
        let cropH = h / divisor
        let rawX = Int(center.x * CGFloat(w)) - cropW / 2
        let rawY = Int(center.y * CGFloat(h)) - cropH / 2
        let cropX = max(0, min(w - cropW, rawX))
        let cropY = max(0, min(h - cropH, rawY))
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard let cropped = img.cropping(to: cropRect) else { return nil }
        return jpegRepresentation(of: cropped, quality: 0.85)
    }

    /// Convenience: crop centered on the frame (kept for the no-position
    /// fallback path).
    public static func centerCrop(_ jpeg: Data, divisor: Int) -> Data? {
        cropAt(jpeg, divisor: divisor, center: CGPoint(x: 0.5, y: 0.5))
    }

    private static func jpegRepresentation(of image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
