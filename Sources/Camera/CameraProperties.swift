import Foundation
import CGPhoto2

/// Read/write exposure properties via the libgphoto2 widget tree.
/// All methods run on `CameraActor`'s pinned thread.
@CameraActor
public final class CameraProperties {
    private let session: CameraSession

    public init(session: CameraSession) {
        self.session = session
    }

    // MARK: - Generic accessors

    public func getString(_ name: String) async throws -> String {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        do {
            let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
            defer { gp_widget_unref(root) }
            let value = try WidgetHelpers.readString(leaf)
            CameraLog.properties.debug("get \(name, privacy: .public) = \(value, privacy: .public)")
            return value
        } catch {
            CameraLog.properties.error("get \(name, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Public setter used by CameraCapture (eosremoterelease=Immediate) and any
    /// caller that needs raw widget write access without going through a
    /// dedicated convenience method. The convenience methods (setIso etc)
    /// still wrap this; this is the one source of truth for the retry loop.
    public func setString(_ name: String, value: String) async throws {
        // Retry up to 3x on GP_ERROR_IO_IN_PROGRESS (-110). That error means
        // libgphoto2's port has another transaction in flight (usually a
        // manual-focus drive that hasn't drained yet). Brief sleep + retry
        // lets the in-flight op complete before our write. Without this,
        // a user changing ISO right after pressing focus buttons sees a
        // permanent error in the UI even though the body itself is fine.
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
                defer { gp_widget_unref(root) }
                try WidgetHelpers.writeString(leaf, value: value)
                try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
                CameraLog.properties.info("set \(name, privacy: .public) ← \(value, privacy: .public)\(attempt > 1 ? " (attempt \(attempt))" : "")")
                return
            } catch CameraError.libGPhoto(let code, _) where code == -110 && attempt < 3 {
                CameraLog.properties.debug("set \(name, privacy: .public): -110 in_progress on attempt \(attempt, privacy: .public), retrying after 250ms")
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            } catch {
                lastError = error
                break
            }
        }
        CameraLog.properties.error("set \(name, privacy: .public) ← \(value, privacy: .public) FAILED: \(String(describing: lastError ?? CameraError.libGPhoto(code: -1, message: "?")), privacy: .public)")
        throw lastError ?? CameraError.libGPhoto(code: -1, message: "set \(name) failed")
    }

    public func choices(for name: String) async throws -> [String] {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
        defer { gp_widget_unref(root) }
        return try WidgetHelpers.choices(leaf)
    }

    // MARK: - Bulk snapshot read

    /// One result of a bulk-snapshot call. Optional fields are missing when the leaf
    /// either doesn't exist on this body or doesn't return readable data.
    public struct Snapshot: Sendable, Equatable {
        public var iso: String?
        public var shutter: String?
        public var aperture: String?
        public var whiteBalance: String?
        public var kelvin: Int?
        public var mode: String?
        public var imageFormat: String?
        public var battery: String?
        public var focusMode: String?
        public var meteringMode: String?
        /// Unix timestamp the camera believes it's at. Read from the `datetime`
        /// widget (TEXT or DATE depending on libgphoto2 build). Used by the
        /// status footer to show whether the body's clock is correct; if it's
        /// wrong, the user can hit the Sync Camera Clock menu item.
        public var cameraDateTime: Date?
    }

    /// Read all common properties in ONE `gp_camera_get_config` traversal. The default
    /// path (one read per property) issues N USB transactions and is ~100ms per call;
    /// bulk-read does one big tree fetch + N in-memory lookups, which is roughly 5× faster
    /// AND much gentler on the body. The 7D in particular gets confused by tight loops
    /// of independent get_config calls (it sometimes returns stale data from libgphoto2's
    /// internal cache or partially-updates the tree mid-read).
    public func snapshot() async throws -> Snapshot {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var root: OpaquePointer? = nil
        try CameraError.check(gp_camera_get_config(cam, &root, ctx))
        guard let root else { throw CameraError.propertyNotFound(name: "<root>") }
        defer { gp_widget_unref(root) }

        // Helper: lookup a leaf in the root we already fetched (no extra USB).
        func leafByName(_ name: String) -> OpaquePointer? {
            var leaf: OpaquePointer? = nil
            let rc = name.withCString { cName in
                gp_widget_get_child_by_name(root, cName, &leaf)
            }
            return (rc == GP_OK) ? leaf : nil
        }

        func readStringLeaf(_ name: String) -> String? {
            guard let leaf = leafByName(name) else { return nil }
            return try? WidgetHelpers.readString(leaf)
        }

        var snap = Snapshot()
        snap.iso = readStringLeaf("iso")
        snap.shutter = readStringLeaf("shutterspeed")
        snap.aperture = readStringLeaf("aperture")
        snap.whiteBalance = readStringLeaf("whitebalance")
        if let kStr = readStringLeaf("colortemperature"), let k = Int(kStr) {
            snap.kelvin = k
        }
        // The 7D libgphoto2 driver normally uses "autoexposuremode"; fall back to
        // "expprogram" for newer builds. Don't issue extra get_config calls for the
        // fallback, both leaves live under the same root we already have.
        snap.mode = readStringLeaf("autoexposuremode") ?? readStringLeaf("expprogram")
        snap.imageFormat = readStringLeaf("imageformat")
        snap.battery = readStringLeaf("batterylevel")
        snap.focusMode = readStringLeaf("focusmode")
        snap.meteringMode = readStringLeaf("meteringmode")
        // Camera datetime is exposed by libgphoto2's Canon EOS driver as a DATE
        // widget at leaf `datetime` (value = Unix timestamp as Int via gp_widget_get_value).
        // Best-effort: read as Int, convert to Date. If the widget is missing
        // or non-numeric, leave nil.
        if let leaf = leafByName("datetime") {
            // DATE widget stores the value as an int (seconds since epoch).
            var ts: Int32 = 0
            let rc = withUnsafeMutablePointer(to: &ts) { ptr in
                gp_widget_get_value(leaf, UnsafeMutableRawPointer(ptr))
            }
            if rc == GP_OK, ts > 0 {
                snap.cameraDateTime = Date(timeIntervalSince1970: TimeInterval(ts))
            }
        }
        return snap
    }

    // MARK: - Choices bulk read (same single-get_config trick)

    public struct ChoiceSet: Sendable, Equatable {
        public var iso: [String]
        public var shutter: [String]
        public var aperture: [String]
        public var whiteBalance: [String]
        public var imageFormat: [String]
        public var meteringMode: [String]

        public init(iso: [String] = [], shutter: [String] = [], aperture: [String] = [],
                    whiteBalance: [String] = [], imageFormat: [String] = [],
                    meteringMode: [String] = []) {
            self.iso = iso
            self.shutter = shutter
            self.aperture = aperture
            self.whiteBalance = whiteBalance
            self.imageFormat = imageFormat
            self.meteringMode = meteringMode
        }
    }

    /// Read all picker choices in ONE config traversal. Same rationale as `snapshot()`.
    public func choicesSnapshot() async throws -> ChoiceSet {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var root: OpaquePointer? = nil
        try CameraError.check(gp_camera_get_config(cam, &root, ctx))
        guard let root else { throw CameraError.propertyNotFound(name: "<root>") }
        defer { gp_widget_unref(root) }

        func choicesByName(_ name: String) -> [String] {
            var leaf: OpaquePointer? = nil
            let rc = name.withCString { cName in
                gp_widget_get_child_by_name(root, cName, &leaf)
            }
            guard rc == GP_OK, let leaf else { return [] }
            return (try? WidgetHelpers.choices(leaf)) ?? []
        }

        return ChoiceSet(
            iso: choicesByName("iso"),
            shutter: choicesByName("shutterspeed"),
            aperture: choicesByName("aperture"),
            whiteBalance: choicesByName("whitebalance"),
            imageFormat: choicesByName("imageformat"),
            meteringMode: choicesByName("meteringmode")
        )
    }

    // MARK: - Typed convenience accessors

    public func iso() async throws -> String {
        try await getString("iso")
    }

    public func setIso(_ value: String) async throws {
        try await assertWritableForExposureProp("iso")
        try await setString("iso", value: value)
    }

    public func shutter() async throws -> String {
        try await getString("shutterspeed")
    }

    public func setShutter(_ value: String) async throws {
        try await assertWritableForExposureProp("shutterspeed")
        try await setString("shutterspeed", value: value)
    }

    public func aperture() async throws -> String {
        try await getString("aperture")
    }

    public func setAperture(_ value: String) async throws {
        try await assertWritableForExposureProp("aperture")
        try await setString("aperture", value: value)
    }

    public func whiteBalance() async throws -> String {
        try await getString("whitebalance")
    }

    public func setWhiteBalance(_ value: String) async throws {
        try await setString("whitebalance", value: value)
    }

    public func whiteBalanceKelvin() async throws -> Int {
        let s = try await getString("colortemperature")
        return Int(s) ?? 0
    }

    public func setWhiteBalanceKelvin(_ k: Int) async throws {
        try await setString("colortemperature", value: "\(k)")
    }

    /// Read the body's current metering mode. Values on the 7D:
    /// "Evaluative" (default, full-frame averaged, weighted toward active AF
    /// point), "Partial" (~6.5% center), "Spot" (~2.3% center, FIXED location),
    /// "Center-weighted average" (whole frame, heavy center bias).
    /// Note: spot meter location can NOT be changed via libgphoto2, the body
    /// hard-codes it to the frame center on this firmware.
    public func meteringMode() async throws -> String {
        try await getString("meteringmode")
    }

    public func setMeteringMode(_ value: String) async throws {
        try await setString("meteringmode", value: value)
    }

    public func meteringModeChoices() async throws -> [String] {
        try await choices(for: "meteringmode")
    }

    /// READ-ONLY, the 7D's exposure mode is set by the physical dial. Throws if you try to write.
    public func exposureMode() async throws -> String {
        // Some libgphoto2 builds expose this as `autoexposuremode`, others as `expprogram`.
        // Try both; whichever resolves wins.
        do { return try await getString("autoexposuremode") } catch {}
        do { return try await getString("expprogram") } catch {}
        throw CameraError.propertyNotFound(name: "autoexposuremode/expprogram")
    }

    public func isoChoices() async throws -> [String] { try await choices(for: "iso") }
    public func shutterChoices() async throws -> [String] { try await choices(for: "shutterspeed") }
    public func apertureChoices() async throws -> [String] { try await choices(for: "aperture") }
    public func whiteBalanceChoices() async throws -> [String] { try await choices(for: "whitebalance") }

    // MARK: - Manual focus drive

    /// Direction + magnitude for a one-shot manual focus step. The 7D's
    /// libgphoto2 driver exposes `manualfocusdrive` as a RADIO with values
    /// "Near 1", "Near 2", "Near 3", "Far 1", "Far 2", "Far 3", "None".
    /// Each step moves the lens motor a small/medium/large amount toward the
    /// near / far end. Multiple writes compound.
    public enum ManualFocusStep: String, Sendable, CaseIterable {
        case nearTiny = "Near 1"   // smallest step toward near
        case nearSmall = "Near 2"
        case nearLarge = "Near 3"  // largest step toward near
        case farTiny = "Far 1"
        case farSmall = "Far 2"
        case farLarge = "Far 3"

        /// Signed magnitude for the client-side relative focus index. Near is
        /// positive, Far negative; 1·2·3 are Canon's fine/medium/coarse presets
        /// (NOT linear multiples, step 3 ≫ 3× step 1, and the exact lens travel
        /// is undocumented and lens-dependent). A directional tracker for
        /// repeatability, never a physical-distance measurement.
        public var weight: Int {
            switch self {
            case .nearTiny:  return 1
            case .nearSmall: return 2
            case .nearLarge: return 3
            case .farTiny:   return -1
            case .farSmall:  return -2
            case .farLarge:  return -3
            }
        }
    }

    /// Drive the lens focus motor one step in the requested direction.
    ///
    /// Important preconditions for the motor to actually MOVE (the libgphoto2
    /// write returns OK regardless, so silent no-ops are common if these
    /// aren't met):
    ///   • Lens switch must be set to AF (the EF lens motor is mechanically
    ///     disconnected in MF, the body sends the drive command and the
    ///     lens accepts it but nothing physical happens).
    ///   • Body focusmode should be a non-Manual mode (One Shot / AI Servo /
    ///     AI Focus). If focusmode is Manual the body itself blocks the
    ///     drive even with the lens switch set correctly. A prior capture can
    ///     leave focusmode=Manual via the capture path, after which the body
    ///     may stay there until the next mode change.
    ///   • Live view should be active. Some Canon bodies only accept
    ///     manualfocusdrive while EVF is up (mirror raised). The 7D in
    ///     particular ignores the command when the mirror is down.
    public func driveManualFocus(_ step: ManualFocusStep) async throws {
        // Force focusmode to "One Shot" before driving, this is what the
        // body needs to honor manualfocusdrive. If focusmode is currently
        // Manual (e.g. from a recent capture's focusmode-Manual write),
        // the drive command would silently no-op. Best-effort.
        do {
            let current = try await getString("focusmode")
            if current.lowercased() == "manual" || current.isEmpty {
                CameraLog.properties.info("driveManualFocus: focusmode=\(current, privacy: .public), forcing One Shot first")
                try? await setString("focusmode", value: "One Shot")
            }
        } catch {
            // focusmode read failed, proceed anyway, write may still work
        }
        try await setString("manualfocusdrive", value: step.rawValue)
    }

    // MARK: - Focus mode

    /// Current focus mode (libgphoto2 typically reports "One Shot", "AI Focus",
    /// "AI Servo", "Manual" on Canon EOS bodies).
    public func focusMode() async throws -> String {
        try await getString("focusmode")
    }

    public func setFocusMode(_ value: String) async throws {
        try await setString("focusmode", value: value)
    }

    public func focusModeChoices() async throws -> [String] {
        try await choices(for: "focusmode")
    }

    // MARK: - AE lock / exposure simulation

    /// Lock auto-exposure. While locked the body holds whatever it metered
    /// at the time of the lock, subsequent captures use that exposure
    /// instead of re-metering. Critical for avoiding the "captured image
    /// is brighter than the LV preview" effect.
    public func setAELock(_ locked: Bool) async throws {
        // libgphoto2 exposes this as TOGGLE `aelock` on Canon EOS. Some
        // bodies don't expose it at all (body has no AE-lock concept), in
        // which case propertyNotFound is thrown and the caller can ignore.
        try await writeToggleAction("aelock", value: locked ? 1 : 0)
    }

    /// Enable exposure simulation in EVF so the LV preview matches what the
    /// body would actually capture. Default on the 7D is OFF (LV always shows
    /// auto-gain'd image regardless of exposure settings).
    /// Returns silently if the widget isn't exposed by this libgphoto2 build.
    public func setExposureSimulation(_ enabled: Bool) async throws {
        // The 7D's libgphoto2 widget for this is typically `eosexposuresimulation`
        // (TOGGLE 0/1). Some bodies/builds expose it as `exposuresimulation` or
        // not at all. Try both leaf names.
        for name in ["eosexposuresimulation", "exposuresimulation"] {
            do {
                let cam = try session.gpCamera()
                let ctx = try session.gpContext()
                let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
                defer { gp_widget_unref(root) }
                try WidgetHelpers.writeToggle(leaf, value: enabled ? 1 : 0)
                try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
                CameraLog.properties.info("set \(name, privacy: .public) ← \(enabled, privacy: .public)")
                return
            } catch CameraError.propertyNotFound {
                continue
            }
        }
        // Both leaf names missing, log and exit silently. Caller treats as
        // best-effort.
        CameraLog.properties.info("exposure simulation widget not exposed; skipping")
    }

    // MARK: - Image format (RAW / RAW+JPEG / JPEG / etc.)

    public func imageFormat() async throws -> String {
        try await getString("imageformat")
    }

    public func setImageFormat(_ value: String) async throws {
        try await setString("imageformat", value: value)
    }

    public func imageFormatChoices() async throws -> [String] {
        try await choices(for: "imageformat")
    }

    // MARK: - Autofocus

    /// Trigger a one-shot autofocus drive on the 7D. Two attempts:
    ///   1. `autofocusdrive` TOGGLE → libgphoto2 maps to EOS_DoAf PTP op.
    ///      The 7D body's PTP firmware decides whether it actually drives
    ///      the lens motor based on focusmode + LV state.
    ///   2. If that returns without an error but the lens didn't move
    ///      (we can't detect that from libgphoto2's return code alone),
    ///      fall back to `eosremoterelease` Press Half + Release Half.
    /// Empirically the Press Half path only meters on the 7D, it doesn't
    /// actually drive the lens. The autofocusdrive widget MAY work
    /// where Press Half doesn't, they call different PTP opcodes.
    public func triggerAutofocus() async throws {
        // autofocusdrive toggle maps to PTP_DPC_CANON_EOS_AutoFocus on EOS
        // bodies. Body responds by driving AF if focusmode is non-Manual
        // and lens is AF.
        //
        // The cancelautofocus chaser was REMOVED because it undid the AF
        // result: the motor runs but the body ends up out of focus and never
        // succeeds at autofocus. Releasing body state isn't worth losing the
        // focus. If AF still leaves the body in a stuck state, the right answer
        // is to remove the AF button entirely (autofocus is optional).
        do {
            try await writeToggleAction("autofocusdrive", value: 1)
            return
        } catch CameraError.propertyNotFound {
            // Widget missing, fall through to eosremoterelease path.
        }
        try await setString("eosremoterelease", value: "Press Half")
        try? await Task.sleep(nanoseconds: 300_000_000)
        try await setString("eosremoterelease", value: "Release Half")
    }

    public func cancelAutofocus() async throws {
        // Cancel via the dedicated widget if exposed; fall back to releasing
        // any active half-press.
        do {
            try await writeToggleAction("cancelautofocus", value: 1)
            return
        } catch CameraError.propertyNotFound {}
        try await setString("eosremoterelease", value: "Release Half")
    }

    /// Sync the camera's clock with optional TZ-offset correction so saved
    /// CR2 files get EXIF DateTimeOriginal that matches host wall clock.
    ///
    /// **Why this exists:** the 7D's `datetimeutc` widget writes the camera's
    /// internal UTC. The body then derives EXIF DateTimeOriginal as
    /// `internal_utc + camera_tz_menu`. If the camera's TZ menu setting doesn't
    /// match the host's TZ, EXIF drifts by the delta. An exact 1-hour gap was
    /// observed with the camera on PST (no DST) while the host was on PDT.
    /// libgphoto2 exposes no widget for the
    /// camera TZ menu so we can't read or fix it from software.
    ///
    /// The 7D does NOT expose a plain `datetime` widget (only `datetimeutc`),
    /// so the previous "write local-clock-as-pseudo-UTC" trick silently fell
    /// back to vanilla syncdatetimeutc, leaving the drift in place.
    ///
    /// **Verified on the R5 (2026-07-28).** That body exposes all four leaves —
    /// `settings/datetime`, `settings/datetimeutc`, `actions/syncdatetime`,
    /// `actions/syncdatetimeutc` — and this function works there unmodified:
    /// a clock skewed by an hour was corrected to within a second, and EXIF
    /// DateTimeOriginal on the resulting CR3 matched host wall clock with a
    /// correct -07:00 / Los Angeles / DST-on zone. `tzOffsetMinutes` is NOT
    /// needed on the R5; leave it at 0.
    ///
    /// One R5 trap worth knowing: `settings/datetime` advertises `Readonly: 0`
    /// but **silently ignores writes** — no error, value simply unchanged.
    /// `settings/datetimeutc` is the one that actually takes, which is what we
    /// write below. Don't "simplify" this to write `datetime`.
    ///
    /// Workaround: pass `tzOffsetMinutes` matching the camera's TZ-menu
    /// delta from host. Camera on PST (-8), host on PDT (-7) → pass +60. The
    /// write becomes `datetimeutc = host_utc + 60min`, the camera computes
    /// local = `(host_utc + 60min) + (-480min) = host_utc - 420min` =
    /// host_local. EXIF then matches Finder. tzOffsetMinutes=0 means "I've
    /// already fixed the camera's TZ menu to match host" and is the proper
    /// long-term fix.
    public func syncDateTimeToHostLocal(tzOffsetMinutes: Int = 0) async throws {
        let now = Date()
        let correctedEpoch = Int32(now.timeIntervalSince1970) + Int32(tzOffsetMinutes * 60)
        // Try writing `datetimeutc` directly (the 7D's actual leaf, exposed
        // as a DATE widget on this driver). If the body presents it as a
        // TEXT widget instead (older libgphoto2 builds did), the action
        // route below handles it.
        do {
            try await writeIntAction("datetimeutc", value: correctedEpoch)
            CameraLog.properties.info("syncDateTimeLocal: wrote datetimeutc=\(correctedEpoch, privacy: .public) (host_utc + \(tzOffsetMinutes, privacy: .public)min)")
            return
        } catch CameraError.widgetTypeMismatch, CameraError.propertyNotFound {
            // Fall through to action-style sync.
        }
        try await writeToggleAction("syncdatetimeutc", value: 1)
        CameraLog.properties.info("syncDateTimeLocal: datetimeutc write rejected, fired syncdatetimeutc action instead (TZ offset NOT applied)")
    }

    /// Legacy entry point, kept so callers that explicitly want UTC sync still
    /// have it. New code should call `syncDateTimeToHostLocal()` because EXIF
    /// timestamps want wall-clock parity, not zone-correct UTC.
    public func syncDateTimeToHost() async throws {
        try await writeToggleAction("syncdatetimeutc", value: 1)
    }

    /// Write an Int-valued widget (used for the `datetime` DATE leaf which
    /// libgphoto2 stores as Unix-seconds Int32).
    private func writeIntAction(_ name: String, value: Int32) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
        defer { gp_widget_unref(root) }
        var v = value
        try withUnsafeMutablePointer(to: &v) { ptr in
            try CameraError.check(gp_widget_set_value(leaf, UnsafeMutableRawPointer(ptr)))
        }
        try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
    }

    /// Write a TOGGLE-typed action leaf, the libgphoto2 convention for fire-once
    /// actions like autofocusdrive, syncdatetimeutc, eosremoterelease, etc.
    private func writeToggleAction(_ name: String, value: Int32) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        do {
            let (root, leaf) = try WidgetHelpers.resolveLeaf(camera: cam, context: ctx, name: name)
            defer { gp_widget_unref(root) }
            try WidgetHelpers.writeToggle(leaf, value: value)
            try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
            CameraLog.properties.info("action \(name, privacy: .public) ← \(value, privacy: .public)")
        } catch {
            CameraLog.properties.error("action \(name, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    // MARK: - Mode-aware write guards

    /// Returns true if a property is writable in the current exposure mode.
    /// Mode dial conventions on the 7D:
    ///   M  → ISO, Tv, Av all writable
    ///   Tv → ISO, Tv writable; Av is auto/read-only
    ///   Av → ISO, Av writable; Tv is auto/read-only
    ///   P  → ISO writable; Tv, Av auto/read-only
    ///   B  → ISO writable; Tv = bulb (read-only); Av writable
    ///   C1/C2/C3 → depends on stored custom mode; treat permissively
    public nonisolated static func isWritable(prop: String, inMode mode: String) -> Bool {
        let normalized = mode.uppercased()
        let isAvMode = normalized.contains("AV") || normalized.contains("APERTURE")
        let isTvMode = normalized.contains("TV") || normalized.contains("SHUTTER")
        let isPMode = normalized.contains("P") && !isAvMode && !isTvMode

        switch prop {
        case "iso":
            return true
        case "shutterspeed":
            if isAvMode || isPMode { return false }
            return true
        case "aperture":
            if isTvMode || isPMode { return false }
            return true
        default:
            return true
        }
    }

    private func assertWritableForExposureProp(_ prop: String) async throws {
        let mode = (try? await exposureMode()) ?? "M"
        if !Self.isWritable(prop: prop, inMode: mode) {
            throw CameraError.propertyReadOnly(name: prop)
        }
    }
}
