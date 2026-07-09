import Foundation
import CGPhoto2

/// Fires the shutter via `gp_camera_capture(GP_CAPTURE_IMAGE)` and downloads
/// the resulting file(s) to a destination folder, byte-for-byte as the camera
/// produced them. The saved extension always comes from the camera's own
/// filename (.CR2 on a 7D, .CR3 on an R5, .JPG for JPEG quality settings),
/// never from the user's filename pattern: an earlier version hardcoded .CR2
/// in the pattern, which mislabeled R5 CR3/JPEG bytes as CR2 and made macOS
/// misreport the format. When the body is set to RAW+JPEG it creates TWO
/// files per shot but gp_camera_capture returns only the first; the companion
/// arrives on the event queue, so we drain FILE_ADDED events after the
/// primary download and save every file of the capture (same base name,
/// each with its own true extension), matching EOS Utility behavior.
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
        /// Primary saved file. When the capture produced multiple files
        /// (RAW+JPEG), this is the RAW; otherwise the only file.
        public let path: URL
        /// Every file this capture saved, primary included. One entry for
        /// RAW-only or JPEG-only quality settings, two for RAW+JPEG.
        public let allPaths: [URL]
        public let timestamp: Date
        public let iso: String?
        public let shutter: String?
        public let aperture: String?
    }

    private let session: CameraSession
    private let properties: CameraProperties
    private let events: CameraEvents
    private var sessionSeq: Int = 0

    public init(session: CameraSession, properties: CameraProperties) {
        self.session = session
        self.properties = properties
        self.events = CameraEvents(session: session)
    }

    public func capture(
        to destinationDir: URL,
        filenamePattern: String = "IMG_{ymd}_{hms}_{seq}.{ext}"
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

        let folderString = withUnsafePointer(to: filePath.folder) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        let nameString = withUnsafePointer(to: filePath.name) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        CameraLog.capture.info("camera file: \(folderString, privacy: .public)/\(nameString, privacy: .public)")

        // RAW+JPEG: the body created a second file for this shot; only the
        // first came back in filePath. The companion is announced via a queued
        // FILE_ADDED event, so drain the queue briefly before naming/saving.
        // Two consecutive 200ms timeouts = queue is empty, stop waiting (a
        // RAW-only or JPEG-only capture pays at most ~400ms here).
        var cameraFiles: [(folder: String, name: String)] = [(folderString, nameString)]
        var consecutiveTimeouts = 0
        let drainDeadline = Date().addingTimeInterval(2.0)
        while Date() < drainDeadline && consecutiveTimeouts < 2 {
            guard let event = try? await events.waitOne(timeoutMs: 200) else { break }
            switch event {
            case .fileAdded(let folder, let name):
                consecutiveTimeouts = 0
                if !cameraFiles.contains(where: { $0.folder == folder && $0.name == name }) {
                    CameraLog.capture.info("companion file: \(folder, privacy: .public)/\(name, privacy: .public)")
                    cameraFiles.append((folder, name))
                }
            case .timeout:
                consecutiveTimeouts += 1
            case .captureComplete, .propertyChanged, .unknown:
                consecutiveTimeouts = 0
            }
        }

        sessionSeq += 1
        let timestamp = Date()
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        // Name every file of this capture from the SAME resolved base; each
        // gets its own true extension straight from the camera's filename.
        var savedURLs: [URL] = []
        for (folder, name) in cameraFiles {
            let cameraExt = (name as NSString).pathExtension
            var resolvedName = Self.resolveFilename(
                pattern: filenamePattern, timestamp: timestamp, sequence: sessionSeq,
                cameraExtension: cameraExt.isEmpty ? nil : cameraExt
            )
            // Same-extension collision within one capture (shouldn't happen,
            // but a body could emit two JPEGs): disambiguate, never overwrite.
            if savedURLs.contains(where: { $0.lastPathComponent == resolvedName }) {
                let ns = resolvedName as NSString
                let ext = ns.pathExtension
                resolvedName = ns.deletingPathExtension + "_2" + (ext.isEmpty ? "" : ".\(ext)")
            }
            let outURL = destinationDir.appendingPathComponent(resolvedName)
            let data = try downloadFile(camera: cam, context: ctx, folder: folder, name: name)
            try data.write(to: outURL, options: .atomic)
            CameraLog.capture.info("wrote \(data.count, privacy: .public) bytes → \(outURL.path, privacy: .public)")
            savedURLs.append(outURL)

            // Delete the on-camera copy so the next capture has a clean slate.
            folder.withCString { folderC in
                name.withCString { nameC in
                    _ = gp_camera_file_delete(cam, folderC, nameC, ctx)
                }
            }
        }
        guard !savedURLs.isEmpty else {
            throw CameraError.captureFailed(reason: "no files downloaded")
        }

        let iso = await isoTask
        let shutter = await shutterTask
        let aperture = await apertureTask

        // Primary = the RAW when the capture produced a RAW+JPEG pair.
        let rawExtensions: Set<String> = ["cr2", "cr3", "crw"]
        let primary = savedURLs.first(where: { rawExtensions.contains($0.pathExtension.lowercased()) })
            ?? savedURLs[0]

        return CaptureResult(
            path: primary,
            allPaths: savedURLs,
            timestamp: timestamp,
            iso: iso,
            shutter: shutter,
            aperture: aperture
        )
    }

    /// Download one on-camera file's bytes via gp_camera_file_get. No
    /// re-encoding anywhere: the returned Data is exactly what the body wrote.
    private func downloadFile(
        camera cam: UnsafeMutablePointer<Camera>,
        context ctx: OpaquePointer,
        folder: String,
        name: String
    ) throws -> Data {
        var file: OpaquePointer? = nil
        try CameraError.check(gp_file_new(&file))
        guard let file else { throw CameraError.captureFailed(reason: "gp_file_new returned NULL") }
        defer { gp_file_unref(file) }

        try folder.withCString { folderC in
            try name.withCString { nameC in
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
        return Data(bytes: dataPtr, count: Int(size))
    }

    /// Resolve `{ymd}`/`{hms}`/`{seq}`/`{ext}` tokens in a filename pattern.
    /// `nonisolated` so the Settings preview can call it directly (it's a pure
    /// function).
    ///
    /// `cameraExtension` is the extension of the file the camera actually
    /// produced (e.g. "CR2", "CR3", "JPG"). When provided, it fills `{ext}`
    /// AND overrides any literal extension in the pattern; the saved name must
    /// never lie about the bytes inside (a pattern hardcoding ".CR2" used to
    /// mislabel R5 CR3/JPEG files). When nil (tests, Settings preview), tokens
    /// resolve but the pattern's literal extension is left alone.
    public nonisolated static func resolveFilename(
        pattern: String, timestamp: Date, sequence: Int, cameraExtension: String? = nil
    ) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        let ymd = String(format: "%04d%02d%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
        let hms = String(format: "%02d%02d%02d", comps.hour ?? 0, comps.minute ?? 0, comps.second ?? 0)
        let seq = String(format: "%04d", sequence)
        var resolved = pattern
            .replacingOccurrences(of: "{ymd}", with: ymd)
            .replacingOccurrences(of: "{hms}", with: hms)
            .replacingOccurrences(of: "{seq}", with: seq)
        if let ext = cameraExtension, !ext.isEmpty {
            resolved = resolved.replacingOccurrences(of: "{ext}", with: ext)
        }
        var name = sanitizeFilename(resolved)
        // Force the true extension when we know it. Patterns from older
        // installs end in a literal ".CR2"; swap it rather than trusting it.
        if let ext = cameraExtension, !ext.isEmpty {
            let ns = name as NSString
            if ns.pathExtension.caseInsensitiveCompare(ext) != .orderedSame {
                name = ns.deletingPathExtension + ".\(ext)"
            }
        }
        return name
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
        if s.isEmpty || s == ".." { s = "IMG" }
        return s
    }
}
