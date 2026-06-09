import Foundation
import CGPhoto2

/// Fires the shutter via `gp_camera_capture(GP_CAPTURE_IMAGE)` and downloads
/// the resulting RAW (.CR2) to a destination folder.
///
/// **Why gp_camera_capture and not eosremoterelease=Immediate.** Using
/// `eosremoterelease=Immediate` (PTP value 5) was wrong: empirical testing
/// showed that this widget write doesn't actually fire the shutter on this 7D.
/// `gphoto2 --set-config eosremoterelease=5 --wait-event-and-download`
/// produced zero files across three attempts. Meanwhile
/// `gphoto2 --capture-image-and-download` (which is exactly
/// `gp_camera_capture(GP_CAPTURE_IMAGE)` underneath) does fire reliably.
/// An apparent "first capture worked" on the Immediate path was almost
/// certainly a stale CR2 in libgphoto2's queue from a previous session, not
/// a fresh exposure.
///
/// **Known body-firmware behaviors with this path:**
///   - The body re-AFs on capture unless the LENS is in MF mode. Our
///     focusmode widget writes silently no-op for AF suppression, the
///     7D firmware ignores the hint and drives a fresh AF pass via its
///     internal Press-Full lifecycle. The lens-switch workaround is the
///     reliable answer for film scanning (focus is locked by the carrier
///     anyway).
///   - The body re-meters in Av/P modes at shutter trigger. There is no
///     widget for AE-lock on this body (verified via `gphoto2 --get-config
///     aelock` → empty). M mode is the only way to make the captured
///     exposure exactly match LV preview.
///   - `gp_camera_capture` hangs when EVF (viewfinder=1) is active, the
///     7D's libgphoto2 driver can't service a capture op with the mirror
///     up. Caller (AppModel.captureNow) drops EVF first via lv.stop, runs
///     this, then restarts LV.
@CameraActor
public final class CameraCapture {
    public struct CaptureResult: Sendable {
        public let path: URL
        public let timestamp: Date
        public let iso: String?
        public let shutter: String?
        public let aperture: String?
    }

    private let session: CameraSession
    private let properties: CameraProperties
    private var sessionSeq: Int = 0

    public init(session: CameraSession, properties: CameraProperties) {
        self.session = session
        self.properties = properties
    }

    public func capture(
        to destinationDir: URL,
        filenamePattern: String = "IMG_{ymd}_{hms}_{seq}.CR2"
    ) async throws -> CaptureResult {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()

        // Snapshot exposure values at capture time for the CaptureResult.
        async let isoTask: String? = try? properties.iso()
        async let shutterTask: String? = try? properties.shutter()
        async let apertureTask: String? = try? properties.aperture()

        // AE lock around capture: with C.Fn IV-1 = "AE lock / AF" set on the
        // body, eosremoterelease=Press Half locks the body's auto-exposure.
        // gp_camera_capture then uses the locked AE instead of re-metering at
        // shutter trigger, which addresses the "captured image is brighter than
        // LV" symptom. Release Half clears the lock afterward. Both writes are
        // best-effort; if the body rejects them we still try the capture.
        //
        // If users have NOT set C.Fn IV-1 to option 1, Press Half here will
        // try to drive AF; this reverts to "re-meter on capture" instead of
        // causing harm.
        try? await properties.setString("eosremoterelease", value: "Press Half")
        // 50ms dwell (was 150ms). The body needs ONE meter pass before
        // capture; 50ms is empirically enough on the 7D's PTP daemon.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // gp_camera_capture(GP_CAPTURE_IMAGE), the standard Canon capture
        // lifecycle. Returns a CameraFilePath pointing at the file the
        // body just wrote. First call after a fresh session sometimes
        // returns -1 ("Could not capture") while the body initializes;
        // one retry with a short delay handles that warm-up case.
        CameraLog.capture.info("gp_camera_capture(GP_CAPTURE_IMAGE) (with AE locked via Press Half) …")
        var filePath = CameraFilePath()
        var rc = gp_camera_capture(cam, GP_CAPTURE_IMAGE, &filePath, ctx)
        if rc != GP_OK {
            CameraLog.capture.info("gp_camera_capture first attempt: rc=\(rc), retrying after 500ms")
            try? await Task.sleep(nanoseconds: 500_000_000)
            rc = gp_camera_capture(cam, GP_CAPTURE_IMAGE, &filePath, ctx)
        }
        // Always release the AE lock, even if capture errored, so the
        // body doesn't stay locked through the next LV preview.
        try? await properties.setString("eosremoterelease", value: "Release Half")
        try CameraError.check(rc)

        // Download.
        var file: OpaquePointer? = nil
        try CameraError.check(gp_file_new(&file))
        guard let file else { throw CameraError.captureFailed(reason: "gp_file_new returned NULL") }
        defer { gp_file_unref(file) }

        let folderString = withUnsafePointer(to: filePath.folder) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        let nameString = withUnsafePointer(to: filePath.name) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }

        try folderString.withCString { folderC in
            try nameString.withCString { nameC in
                try CameraError.check(
                    gp_camera_file_get(cam, folderC, nameC, GP_FILE_TYPE_NORMAL, file, ctx)
                )
            }
        }

        var dataPtr: UnsafePointer<CChar>? = nil
        var size: UInt = 0
        try withUnsafeMutablePointer(to: &dataPtr) { dPtr in
            try withUnsafeMutablePointer(to: &size) { sPtr in
                try CameraError.check(gp_file_get_data_and_size(file, dPtr, sPtr))
            }
        }
        guard let dataPtr, size > 0 else {
            throw CameraError.captureFailed(reason: "empty file data")
        }
        let data = Data(bytes: dataPtr, count: Int(size))

        sessionSeq += 1
        let timestamp = Date()
        let resolvedName = Self.resolveFilename(
            pattern: filenamePattern, timestamp: timestamp, sequence: sessionSeq
        )
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let outURL = destinationDir.appendingPathComponent(resolvedName)
        try data.write(to: outURL, options: .atomic)
        CameraLog.capture.info("wrote \(data.count, privacy: .public) bytes → \(outURL.path, privacy: .public)")

        // Delete the on-camera copy so the next capture has a clean slate.
        folderString.withCString { folderC in
            nameString.withCString { nameC in
                _ = gp_camera_file_delete(cam, folderC, nameC, ctx)
            }
        }

        let iso = await isoTask
        let shutter = await shutterTask
        let aperture = await apertureTask

        return CaptureResult(
            path: outURL,
            timestamp: timestamp,
            iso: iso,
            shutter: shutter,
            aperture: aperture
        )
    }

    /// Resolve `{ymd}`/`{hms}`/`{seq}` tokens in a filename pattern. `nonisolated`
    /// so the Settings preview can call it directly (it's a pure function).
    public nonisolated static func resolveFilename(pattern: String, timestamp: Date, sequence: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        let ymd = String(format: "%04d%02d%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        let hms = String(format: "%02d%02d%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
        let seq = String(format: "%04d", sequence)
        let resolved = pattern
            .replacingOccurrences(of: "{ymd}", with: ymd)
            .replacingOccurrences(of: "{hms}", with: hms)
            .replacingOccurrences(of: "{seq}", with: seq)
        return sanitizeFilename(resolved)
    }

    /// Reduce a resolved name to a single safe path component so a user-set
    /// pattern can never write outside the chosen capture folder. Strips any
    /// directory parts (keeps the final segment), neutralizes path separators
    /// and parent-dir traversal, and never yields a hidden/empty name. If you
    /// ever want pattern-driven subfolders, add that as an explicit, validated
    /// feature rather than relaxing this.
    nonisolated static func sanitizeFilename(_ name: String) -> String {
        var s = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        while s.hasPrefix(".") { s.removeFirst() }
        if s.isEmpty || s == ".." { s = "IMG.CR2" }
        return s
    }
}
