import Foundation
import CGPhoto2
import UsbReset

/// Owns the libgphoto2 `Camera*` and `GPContext*` for a single connected camera.
/// All methods run on `CameraActor`'s pinned thread.
@CameraActor
public final class CameraSession {
    private var camera: UnsafeMutablePointer<Camera>?
    private var context: OpaquePointer?
    public private(set) var isOpen: Bool = false

    /// Firmware version reported by the camera (e.g. "2.0.6"). Populated after `open()`.
    public private(set) var firmware: String?

    public init() throws {
        // Belt-and-suspenders: ensure CAMLIBS/IOLIBS env is set before any libgphoto2 call.
        // AppLaunch.bootstrap should have set these at process start, but if this class is
        // instantiated from a test or a non-main entry point, re-run setup idempotently.
        CameraEnvironment.setup()

        var newCamera: UnsafeMutablePointer<Camera>? = nil
        try CameraError.check(gp_camera_new(&newCamera))
        self.camera = newCamera
        self.context = gp_context_new()
        if self.context == nil {
            if let c = newCamera { gp_camera_unref(c) }
            throw CameraError.libGPhoto(code: -1, message: "gp_context_new returned NULL")
        }
    }

    deinit {
        // deinit runs on whatever thread released the final reference, NOT the pinned
        // camera thread. So we must NOT call gp_camera_exit here (that's a USB transaction
        // and would violate the pinned-thread invariant). gp_camera_unref / gp_context_unref
        // are pure ref-count + memory-free operations with no USB I/O, so they're safe to
        // call from any thread (libgphoto2 source: gp_camera_unref → free_camera).
        //
        // If isOpen is true at deinit time, the caller failed to call close(), we'll leak the
        // USB endpoint until process exit (which is OK because process exit closes USB anyway).
        if let cam = camera { gp_camera_unref(cam) }
        if let ctx = context { gp_context_unref(ctx) }
    }

    /// Initialize the camera connection. Must be preceded by `ICDeviceClaim.releaseCanonEos()`
    /// to avoid the macOS PTPCamera USB-claim race.
    public func open() async throws {
        guard !isOpen else { throw CameraError.sessionAlreadyOpen }
        guard let cam = camera, let ctx = context else {
            throw CameraError.sessionNotOpen
        }
        // Defensive recovery sequence, if a prior process crashed mid-EVF
        // the body's PTP session can be stuck. gp_camera_exit + ~150ms gives
        // the body time to time-out the orphaned session before we re-init.
        // No-op on a never-opened camera (no session to exit).
        _ = gp_camera_exit(cam, ctx)
        try? await Task.sleep(nanoseconds: 150_000_000)

        CameraLog.session.info("gp_camera_init …")
        var initResult = gp_camera_init(cam, ctx)
        if initResult == GP_ERROR_TIMEOUT || initResult == GP_ERROR_IO || initResult == -7 || initResult == -53 {
            // First-line recovery: gp_camera_exit + brief wait + retry. Handles
            // the common case where libgphoto2's port state is stale but the
            // body's PTP daemon is healthy.
            CameraLog.session.info("gp_camera_init returned \(initResult), attempting soft retry")
            _ = gp_camera_exit(cam, ctx)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            CameraLog.session.info("gp_camera_init (soft retry) …")
            initResult = gp_camera_init(cam, ctx)
        }
        if initResult == GP_ERROR_TIMEOUT || initResult == GP_ERROR_IO || initResult == -7 || initResult == -53 {
            // Heavy-hammer recovery: USB device re-enumerate via IOKit. This
            // is functionally equivalent to physically unplugging + replugging
            // the camera, the body's PTP daemon fully resets. Use only after
            // the soft retry above already failed; ReEnumerate makes the device
            // disappear briefly so it's intrusive.
            CameraLog.session.info("soft retry failed; issuing IOKit USB ReEnumerate on Canon (0x04A9)")
            _ = gp_camera_exit(cam, ctx)
            let resetRc = filmtether_reset_usb_device(0x04A9)
            CameraLog.session.info("filmtether_reset_usb_device → \(resetRc) (0=ok, -1=not found, -2/-3=IOKit fail, -4=exclusive, -5=re-enumerate fail)")
            if resetRc == 0 {
                // ReEnumerate disconnected our pre-existing libgphoto2 Camera handle.
                // The old cam pointer now references a stale io_service_t, any call
                // on it returns GP_ERROR_BAD_PARAMETERS (-2). We must re-allocate the
                // libgphoto2 camera object so it discovers the freshly-enumerated
                // device. Wait first so the body has time to come back online.
                CameraLog.session.info("waiting 6s for body PTP daemon to come back …")
                try? await Task.sleep(nanoseconds: 6_000_000_000)

                // Re-create the libgphoto2 camera handle bound to the new device.
                gp_camera_unref(cam)
                self.camera = nil
                var freshCam: UnsafeMutablePointer<Camera>? = nil
                try CameraError.check(gp_camera_new(&freshCam))
                guard freshCam != nil else {
                    throw CameraError.libGPhoto(code: -1, message: "gp_camera_new returned null after USB reset")
                }
                self.camera = freshCam
                CameraLog.session.info("gp_camera_init (after USB reset, fresh handle) …")
                initResult = gp_camera_init(freshCam, ctx)
            }
        }
        try CameraError.check(initResult)
        isOpen = true
        CameraLog.session.info("gp_camera_init → GP_OK")

        // Capturetarget write moved out of open() after the 7D hit a fatal
        // "shooting is not possible" error on app restart with no user action.
        // The only writes we did on connect were syncdatetimeutc and
        // capturetarget; making the connect path purely read-only (just init +
        // summary parse) and deferring writes until the user actually needs
        // them eliminates the trigger surface.
        // Capturetarget is now lazily set the first time `ensureCaptureTargetRAM()`
        // is called (from CameraCapture before each capture).

        // Read firmware via summary; throw only if it matches the known-buggy blocklist.
        if let detected = try readFirmwareVersion() {
            firmware = detected
            CameraLog.session.info("firmware: \(detected, privacy: .public)")
            if isFirmwareTooOld(detected) {
                CameraLog.session.error("firmware \(detected, privacy: .public) is on the known-buggy list, refusing to proceed")
                isOpen = false
                _ = gp_camera_exit(cam, ctx)
                throw CameraError.firmwareTooOld(detected: detected)
            }
        } else {
            CameraLog.session.info("firmware: not parseable from summary (OK for many bodies)")
        }
    }

    public func close() {
        guard isOpen, let cam = camera, let ctx = context else { return }
        _ = gp_camera_exit(cam, ctx)
        isOpen = false
    }

    /// Internal accessors for peer classes in this module.
    internal func gpCamera() throws -> UnsafeMutablePointer<Camera> {
        guard isOpen, let c = camera else { throw CameraError.sessionNotOpen }
        return c
    }

    internal func gpContext() throws -> OpaquePointer {
        guard let c = context else { throw CameraError.sessionNotOpen }
        return c
    }

    // MARK: - Private

    private func setCaptureTargetInternalRAM() throws {
        guard let cam = camera, let ctx = context else { return }
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "capturetarget"
        )
        defer { gp_widget_unref(root) }

        // libgphoto2 exposes capturetarget as a RADIO of "Internal RAM" / "Memory card".
        try WidgetHelpers.writeString(leaf, value: "Internal RAM")
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "capturetarget", leaf: leaf)
    }

    private func readFirmwareVersion() throws -> String? {
        guard let cam = camera, let ctx = context else { return nil }
        var summary = CameraText()
        try CameraError.check(gp_camera_get_summary(cam, &summary, ctx))

        // CameraText.text is a 32 KB C array, Swift's importer hides huge fixed-size arrays
        // as inaccessible fields. Read it via raw memory: the struct's address IS the address
        // of its first (and only) field, so we rebind the struct pointer as `CChar*`.
        let text = withUnsafePointer(to: summary) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
        return parseFirmware(from: text)
    }

    /// Parse "Firmware Version: X.Y.Z" out of `gp_camera_get_summary` output.
    /// Returns nil if not found. Public for testability.
    public static func parseFirmware(from summary: String) -> String? {
        // Try several known patterns, libgphoto2 summary format varies across camlibs.
        let patterns = [
            #"Firmware\s+Version[:\s]+([0-9]+(?:\.[0-9]+)+)"#,
            #"Firmware[:\s]+([0-9]+(?:\.[0-9]+)+)"#,
        ]
        for p in patterns {
            if let r = summary.range(of: p, options: .regularExpression) {
                let match = String(summary[r])
                // Extract the version substring.
                if let v = match.range(of: #"[0-9]+(?:\.[0-9]+)+"#, options: .regularExpression) {
                    return String(match[v])
                }
            }
        }
        return nil
    }

    private func parseFirmware(from summary: String) -> String? {
        Self.parseFirmware(from: summary)
    }

    /// Returns true if `version` is on the known-buggy-firmware list.
    /// Currently only the Canon EOS 7D's firmware 2.0.3 is flagged (gphoto2 issue #460:
    /// PTP I/O error on capture-image). Other bodies, including the 70D running its
    /// usual 1.x firmware, pass through fine.
    public static func isFirmwareTooOld(_ version: String) -> Bool {
        knownBuggyFirmwares.contains(version)
    }

    private static let knownBuggyFirmwares: Set<String> = [
        "2.0.3", // Canon 7D, see gphoto2 issue #460
    ]

    private func isFirmwareTooOld(_ version: String) -> Bool {
        Self.isFirmwareTooOld(version)
    }
}
