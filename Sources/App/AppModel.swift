import Foundation
import SwiftUI
import AppKit
import os
import Camera
import Hotkey

private let appLog = Logger(subsystem: "co.wonders.filmtether", category: "AppModel")
private let hotkeyLog = Logger(subsystem: "co.wonders.filmtether", category: "Hotkey")

/// Build identity, injected into Info.plist by scripts/bundle.sh (git short hash
/// + build time). Surfaced in the window title so we can always confirm exactly
/// which build is running.
enum AppInfo {
    static var buildStamp: String {
        (Bundle.main.infoDictionary?["BuildStamp"] as? String) ?? "dev"
    }

    /// Where the in-app "supported cameras" links point. The app UI stays
    /// camera-agnostic ("compatible camera"); the authoritative tested/supported
    /// list lives in the public repo. TODO(publish): set to the real public
    /// repo URL once the GitHub release repo is created.
    static let supportedCamerasURL = URL(string: "https://github.com/chriscantey/film-tether#supported-cameras")!
}

@MainActor
final class AppModel: ObservableObject {
    enum UIState: Equatable {
        case disconnected
        case enumerating
        case ready
        case streaming
        case error(message: String, hint: String?)
    }

    struct PropertySnapshot: Equatable {
        // Raw values straight from libgphoto2 (terse strings like "160", "2.8",
        // "0.005", "AV"). Kept around so picker writes round-trip exactly the
        // value libgphoto2 expects.
        var iso: String = "—"
        var shutter: String = "—"
        /// Last non-"Auto" shutter value observed during this session. In Av
        /// mode the body returns "Auto" most of the time and a numeric value
        /// briefly after a metering pass, this field captures that brief
        /// numeric value and persists it so the user always sees what the
        /// camera most-recently decided. Updated by AppModel.refreshSnapshot.
        var meteredShutter: String? = nil
        var aperture: String = "—"
        var whiteBalance: String = "—"
        var whiteBalanceKelvin: Int? = nil
        var mode: String = "—"
        var imageFormat: String = "—"
        var battery: String = "—"
        var meteringMode: String = "—"
        var cameraDateTime: Date? = nil
        var fps: Double = 0

        // Pretty-formatted display strings. Computed from raw values via
        // PropertyLabels, UI shows these.
        var isoLabel: String { PropertyLabels.iso(iso) }
        var shutterLabel: String { PropertyLabels.shutter(shutter) }
        var apertureLabel: String { PropertyLabels.aperture(aperture) }
        var whiteBalanceLabel: String { PropertyLabels.whiteBalance(whiteBalance) }
        var kelvinLabel: String { PropertyLabels.kelvin(whiteBalanceKelvin) }
        var modeLabel: String { PropertyLabels.exposureMode(mode) }
        var imageFormatLabel: String { PropertyLabels.imageFormat(imageFormat) }
        var batteryLabel: String { PropertyLabels.battery(battery) }
    }

    @Published private(set) var ui: UIState = .disconnected
    @Published private(set) var snapshot = PropertySnapshot()
    @Published private(set) var latestFrame: NSImage? = nil
    @Published private(set) var lastCapture: String? = nil
    @Published private(set) var capturedFiles: [URL] = []
    @Published private(set) var zoomMode: LiveZoom.Mode = .fit
    @Published private(set) var zoomFallbackActive: Bool = false
    /// Relative focus index: client-side running total of commanded manual-focus
    /// step magnitudes (Near +, Far −) since the last reset. The camera reports
    /// no absolute focus position, so this is a directional tracker for
    /// repeatability, NOT physical distance. Reset via `resetFocusPosition()`.
    @Published private(set) var focusStepPosition: Int = 0
    @Published private(set) var isoChoices: [String] = []
    @Published private(set) var shutterChoices: [String] = []
    @Published private(set) var apertureChoices: [String] = []
    @Published private(set) var imageFormatChoices: [String] = []
    @Published private(set) var meteringModeChoices: [String] = []
    @Published private(set) var permissionsState: PermissionsState = .init()
    /// Diagnostic: incremented on every successful snapshot refresh. Used to
    /// verify @Published observation is wired correctly when UI fields appear
    /// stuck at defaults despite the backing values updating.
    @Published private(set) var snapshotTick: Int = 0
    /// Toggle for the metering / zoom box overlay in the LV pane. Default
    /// is now ON (like the Cmd-P toggle, it should just stay on) and persisted
    /// via AppSettings.
    var showMeteringOverlay: Bool {
        get { AppSettings.shared.showMeteringOverlay }
        set {
            AppSettings.shared.showMeteringOverlay = newValue
            objectWillChange.send()
        }
    }
    /// Normalized [0,1] x [0,1] center point of the metering / zoom rect.
    /// Default = dead center. Drag on the overlay updates this.
    @Published var meteringCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Focus peaking overlay toggle. Persisted via AppSettings so the
    /// last on/off state is remembered across launches.
    var focusPeakingEnabled: Bool {
        get { AppSettings.shared.focusPeakingEnabled }
        set {
            AppSettings.shared.focusPeakingEnabled = newValue
            objectWillChange.send()
        }
    }

    /// Color of the peaking overlay, proxied to AppSettings so the choice
    /// persists across launches and the Settings UI's swatch grid stays in
    /// sync with the Cmd-Shift-P cycle.
    var focusPeakingColor: FocusPeaking.PeakColor {
        get { AppSettings.shared.focusPeakingColor }
        set {
            AppSettings.shared.focusPeakingColor = newValue
            objectWillChange.send()
        }
    }

    /// Detection mode (edges vs grain). Same persistence story as color.
    var focusPeakingMode: FocusPeaking.Mode {
        get { AppSettings.shared.focusPeakingMode }
        set {
            AppSettings.shared.focusPeakingMode = newValue
            objectWillChange.send()
        }
    }

    /// Cycle to the next peaking color. Wraps around after the last.
    func cycleFocusPeakingColor() {
        let all = FocusPeaking.PeakColor.allCases
        guard let idx = all.firstIndex(of: focusPeakingColor) else {
            focusPeakingColor = all.first ?? .cyan
            return
        }
        focusPeakingColor = all[(idx + 1) % all.count]
        appLog.info("focus peaking color → \(self.focusPeakingColor.rawValue, privacy: .public)")
    }
    var isLiveViewOn: Bool { ui == .streaming }

    struct PermissionsState: Equatable {
        var accessibility: Bool = false
        var inputMonitoring: Bool = false
    }

    // Held by AppModel after the connection is ready.
    private var connection: CameraConnection?
    private var session: CameraSession?
    private var properties: CameraProperties?
    private var capture: CameraCapture?
    private var liveView: LiveView?
    private var liveZoom: LiveZoom?
    private var hotkey: HoldKeyMonitor?
    private var connectionTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    private var hotkeyTask: Task<Void, Never>?
    private var snapshotRefreshTask: Task<Void, Never>?
    /// Background drain of libgphoto2's event queue. Runs continuously while
    /// connected so we pick up property-change events the body emits during
    /// EVF (shutterspeed changes from the auto-meter, focusmode toggles,
    /// lensname on attach, etc). Without this loop the only way to learn
    /// the body's current state was to ask via gp_camera_get_config, which
    /// fights the EVF stream for the USB pipe. Event drain is push-based
    /// and free; the body is going to emit the events whether we drain
    /// them or not. Source: gphoto2 --wait-event probe on the 7D.
    private var eventDrainTask: Task<Void, Never>?
    /// Periodic meter-kick task. Fires Press Half / Release Half every ~2s
    /// during LV so the body emits a shutterspeed change event reflecting
    /// the CAPTURE-meter value (which on this body differs from the LV
    /// meter; the footer can read 1/100 while capture fires 1/150).
    /// Runs only while LV is streaming; cancelled before LV teardown so
    /// the body has a quiet pipe for viewfinder=0.
    private var meterKickTask: Task<Void, Never>?
    /// Holds CameraEvents on the actor side. Wrapped here so the event-drain
    /// task can reach it via a weak self.
    private var cameraEvents: CameraEvents?
    /// Zoom probe spawned by startLiveView. Must be cancelled in stopLiveView,
    /// otherwise its pending setZoom + fetchOnePreview calls will fire *after*
    /// the user's stop, re-opening the EVF (shutter re-opens audibly) and
    /// leaving the body in a state where the next Start is a no-op.
    private var zoomProbeTask: Task<Void, Never>?
    /// Cached zoom-probe result. Once we know whether camera-side zoom works
    /// for this session we don't re-run the probe on every LV start.
    private var zoomProbed: Bool = false
    private var fpsLastFrameAt: Date? = nil
    private var emaFps: Double = 0
    private var captureKeyMonitor: Any?
    /// Where the camera-side zoom box is currently centered, in body pixel
    /// coordinates. Updated by zoom-engage (synced from meteringCenter) and
    /// by each arrow nudge. Previously each nudge sent (center + step)
    /// regardless of where the body was zoomed, so arrows nudged left/right
    /// only once and then stopped moving. Stateful tracking fixes that.
    private var zoomBodyCenter: (x: Int, y: Int) = (2592, 1728)  // Evf-space center (5184×3456/2); recomputed on zoom
    /// Canon's `eoszoomposition` lives in the Evf (full-image) coordinate
    /// system, measured via an x-sweep on the 7D: x=0 → left edge,
    /// x≈2000 → middle, x≈4147 → right clamp. That's the 5184×3456 full-image
    /// space (NOT the 1056×704 LV JPEG; an earlier 1024×680 assumption is
    /// exactly why positioning never moved off the left edge). This is
    /// the same big coordinate system EOS Utility drives.
    /// Measured `eoszoomposition` mapping (template-match calibration,
    /// NCC 0.995 on two frames). The zoom rect's top-left in the
    /// 1056×704 OUTPUT relates to the eoszoomposition value by a straight line:
    ///   fit_px = origin + eoszoom × fitPxPerUnit
    /// Pinned exactly by x=0→fit-x 46 and x=3000→fit-x 617 (slope 0.1903,
    /// origin 46). We invert it to drive the zoom to where the box is. The
    /// +46/+50 origin (camera's zoom origin isn't the frame corner) was the
    /// systematic offset that made earlier mapping land short.
    /// Inverse of the camera's MEASURED zoom response (5-point corner+center
    /// dump). The 7D's eoszoom space maps to an INSET, COMPRESSED region of
    /// the displayed FOV (FOV/scale relationship, confirmed):
    /// eoszoom (0,0) lands the zoom CENTER at (0.133, 0.222), not the corner,     /// and eoszoom (4455,3120) lands it at (0.855, 0.842). So we invert that
    /// response: eoszoom = (box - offset) × gain, clamped to the camera range.
    /// Hardware limit: eoszoom can't go negative, so the zoom can't reach above
    /// ~0.12 (top) or left of ~0.04, a real 7D border, not a software bug.
    static let zoomRespOffset = CGPoint(x: 0.133, y: 0.222)
    static let zoomRespGain   = CGPoint(x: 6168, y: 5033)   // 1/measured-slope
    static let zoomEoszoomMax = CGPoint(x: 5000, y: 3800)   // camera clamps internally too
    /// The 5× zoom region as a fraction of the frame (measured 0.199). The box
    /// is drawn this size; the clamp + nudge use it too.
    static let zoomBoxFraction: CGFloat = 0.199
    private var observedLVFrameSize: (w: Int, h: Int)?

    // MARK: - Lifecycle

    func start() async {
        refreshPermissions()
        startCaptureKeyMonitor()
        let conn = await CameraConnection()
        self.connection = conn
        connectionTask = Task { [weak self] in
            await conn.startMonitoring()
            for await state in conn.stateStream {
                await self?.handleConnectionState(state)
            }
        }
    }

    func stop() async {
        connectionTask?.cancel()
        liveViewTask?.cancel()
        hotkeyTask?.cancel()
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        eventDrainTask?.cancel()
        eventDrainTask = nil
        meterKickTask?.cancel()
        meterKickTask = nil
        cameraEvents = nil
        hotkey?.stop()
        if let monitor = captureKeyMonitor {
            NSEvent.removeMonitor(monitor)
            captureKeyMonitor = nil
        }
        if let lv = liveView { try? await lv.stop() }   // cancels the LV loop (+ async EVF teardown)
        // Close the libgphoto2 session so the USB/PTP claim is released.
        // stopMonitoring() already calls session.close() (gp_camera_exit, which
        // also drops EVF), but we await it explicitly too for safety. The slow
        // explicit viewfinder/output writes that used to be here were REMOVED:
        // they were USB transactions that blew applicationWill-
        // Terminate's ~4s budget, so the close never ran, producing a long quit
        // with the camera left open. gp_camera_exit handles the EVF teardown.
        if let conn = connection { await conn.stopMonitoring() }
        await session?.close()
        connection = nil
        session = nil
        properties = nil
        capture = nil
        liveView = nil
        liveZoom = nil
    }

    // MARK: - Connection-state handling

    private func handleConnectionState(_ state: CameraConnection.ConnectionState) async {
        switch state {
        case .disconnected:
            self.session = nil
            self.properties = nil
            self.capture = nil
            self.liveView = nil
            self.liveZoom = nil
            self.ui = .disconnected
            self.latestFrame = nil
            // Reset per-session state so the next connection re-probes zoom etc.
            self.zoomProbed = false
            zoomProbeTask?.cancel()
            zoomProbeTask = nil
            liveViewTask?.cancel()
            liveViewTask = nil
        case .enumerating:
            self.ui = .enumerating
        case .ready:
            guard let conn = connection else {
                self.ui = .error(message: "Connection ready but no connection object.", hint: nil)
                return
            }
            guard let sess = await conn.currentSession() else {
                self.ui = .error(message: "Connection ready but no session.", hint: nil)
                return
            }
            self.session = sess
            let props = await CameraProperties(session: sess)
            self.properties = props
            self.capture = await CameraCapture(session: sess, properties: props)
            let lv = await LiveView(session: sess, properties: props)
            self.liveView = lv
            self.liveZoom = await LiveZoom(session: sess)
            let evts = await CameraEvents(session: sess)
            self.cameraEvents = evts
            self.ui = .ready
            // Datetime sync was previously automatic on every connect. A body
            // went into the fatal "shooting is not possible, remove the
            // battery" error during an app restart with nothing else changing,
            // which is symptomatic of a libgphoto2 widget write that the 7D
            // firmware can't handle in some state. syncdatetimeutc was the
            // only write on the connect path, so it's the prime suspect. Now
            // user-triggered only, call model.syncCameraClock() from a menu.
            // Start the frame consumer ONCE per connection. AsyncStream isn't a
            // proper multicast subject, re-iterating it across stop/start cycles
            // (which the previous design did by recreating liveViewTask in
            // startLiveView) caused the second iterator to see an empty stream,
            // even when runLoop was clearly yielding frames per logs.
            // Long-lived consumer: runLoop's start()/stop() controls whether
            // frames flow; this loop just drains whatever arrives.
            liveViewTask?.cancel()
            liveViewTask = Task { [weak self] in
                for await frame in lv.frameStream {
                    await self?.handleFrame(frame)
                }
            }
            await refreshSnapshot()
            await loadChoices()
            startHotkey()
            startSnapshotRefresh()
            // NOTE: eventDrainTask is NOT started here. Starting it at
            // connect-ready meant the drain held the actor continuously
            // while idle, which kept the body's PTP daemon busy enough
            // that subsequent setViewfinder(0/1) writes failed to actually
            // move the mirror: the mirror failed to close or open on
            // Stop/Start. Drain only
            // matters during LV (metered Tv is an LV-only signal), so we
            // start it in startLiveView() and stop it in stopLiveView().
            // Opt-in auto-sync of the camera clock to host LOCAL wall time.
            // Default ON in AppSettings so the date is set automatically.
            // Local (not UTC)
            // is the fix for the EXIF DateTimeOriginal drift on bodies whose
            // internal TZ setting doesn't match the host (see
            // CameraProperties.syncDateTimeToHostLocal for the full story).
            if AppSettings.shared.autoSyncClockOnConnect {
                Task { [weak self] in await self?.syncCameraClockLocal() }
            }
        case .error(let msg):
            self.ui = .error(message: msg, hint: hintForMessage(msg))
        }
    }

    private func hintForMessage(_ msg: String) -> String? {
        let lower = msg.lowercased()
        if lower.contains("firmware") { return "Update your camera's firmware to the latest supported version (camera menu → wrench → Firmware Ver.)." }
        if lower.contains("usb") || lower.contains("claim") { return "Quit Image Capture and Photos, then unplug/replug the camera." }
        if lower.contains("timeout") || lower.contains("i/o") {
            return "Camera may be in a wedged state. Power the camera off, wait 3 seconds, power it on. The app will reconnect automatically."
        }
        if lower.contains("not detected") || lower.contains("no") { return "Set the camera's Communication menu to PTP." }
        return nil
    }

    // MARK: - Live view

    func startLiveView() async {
        appLog.info("startLiveView() called")
        guard let lv = liveView, let zoom = liveZoom else {
            appLog.error("startLiveView: liveView or liveZoom nil")
            return
        }
        // Reset overlay rect to dead center every LV session so it returns to
        // the center of the frame each time.
        self.meteringCenter = CGPoint(x: 0.5, y: 0.5)
        do {
            try await lv.start()
            self.ui = .streaming
            appLog.info("startLiveView: ui → .streaming")
            // Event drain is LV-coupled, only useful for picking up metered
            // Tv changes, which only happen during EVF. Start it after the
            // mirror is up; cancel in stopLiveView so the next mirror-down
            // write has a quiet PTP channel.
            startEventDrain()
            // startMeterKick() REMOVED, every-2s Press Half writes wedged
            // the body's firmware (needed power-cycle to recover). The 7D
            // can't tolerate sustained Press Half cycling even with C.Fn
            // IV-1 = AE lock. Tradeoff: footer's metered shutter no longer
            // updates in real-time; it only reflects what the LV-meter
            // emits (rare in Av/P modes) plus what arrives via the once-
            // per-capture Press Half. There may be NO safe way to get
            // real-time capture-meter parity on this body via libgphoto2.
            // NOTE: liveViewTask is started ONCE per connection in
            // handleConnectionState(.ready). Recreating it here would re-iterate
            // an already-consumed AsyncStream and silently see no frames.

            // 7D-only: we already know from prior probes that camera-side
            // eoszoom works (returns supported=true every time). Skipping the
            // probe entirely eliminates the visible "flash of zoom" on
            // LV start, the probe was running setZoom(.fivex) then back
            // to .fit which was visible in the preview pane. Hardcoded to
            // supported=true; zoomFallbackActive stays false.
            zoomProbed = true
            zoomFallbackActive = false
            _ = zoom  // silence unused warning while keeping the parameter shape
        } catch let err as CameraError {
            appLog.error("startLiveView CameraError: \(err.localizedDescription, privacy: .public)")
            self.ui = .error(message: err.localizedDescription, hint: nil)
        } catch {
            appLog.error("startLiveView error: \(String(describing: error), privacy: .public)")
            self.ui = .error(message: "\(error)", hint: nil)
        }
    }

    func stopLiveView() async {
        appLog.info("stopLiveView() called (ui=\(String(describing: self.ui), privacy: .public))")
        zoomProbeTask?.cancel()
        zoomProbeTask = nil
        // Stop the event drain AND the meter-kick BEFORE writing viewfinder=0,
        // so the body's PTP daemon has a quiet channel to actually drop the
        // mirror.
        eventDrainTask?.cancel()
        eventDrainTask = nil
        meterKickTask?.cancel()
        meterKickTask = nil
        if let lv = liveView {
            do { try await lv.stop(); appLog.info("LiveView.stop() OK") }
            catch { appLog.error("LiveView.stop() failed: \(String(describing: error), privacy: .public)") }
        }
        if case .streaming = ui { self.ui = .ready; appLog.info("stopLiveView: ui → .ready") }
        latestFrame = nil
        // Reset zoom state so the next LV session starts at fit + center,
        // not whatever the last session left it at. Without this, the body's
        // zoom position persists across LV restarts (because we never
        // explicitly set it back to fit/center on stop) and the next Space-
        // hold zooms to the prior position instead of the current overlay
        // location.
        zoomMode = .fit
        zoomBodyCenter = (2592, 1728)  // Evf-space center; recomputed on next zoom anyway
    }

    private func handleFrame(_ frame: LiveView.Frame) async {
        // Gate on streaming state. The long-lived liveViewTask continues
        // draining lv.frameStream even after the user hits Stop, if runLoop
        // had a frame buffered when we cancelled, it'll arrive here and
        // overwrite latestFrame back to the old image. Dropping post-stop
        // frames keeps the preview pane truly empty when live view is off.
        guard ui == .streaming else { return }
        let now = Date()
        if let last = fpsLastFrameAt {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                let instantaneous = 1.0 / dt
                emaFps = emaFps == 0 ? instantaneous : (emaFps * 0.8 + instantaneous * 0.2)
                snapshot.fps = emaFps
            }
        }
        fpsLastFrameAt = now

        // Capture the FIT-frame dimensions so applyZoom positions eoszoom in
        // the right coordinate space. Only sample while at fit: the body
        // streams a different size when punched in (verified empirically:
        // fit=1056×704, zoom5×=1024×680), and eoszoomposition coordinates are
        // in the fit-frame space, sampling the zoomed size would skew the
        // reposition math during arrow-nudges.
        if zoomMode == .fit, let w = frame.width, let h = frame.height, w > 0, h > 0 {
            observedLVFrameSize = (w: w, h: h)
        }
        var jpeg = frame.jpegData
        // Client-side JPEG crop is now a FALLBACK only. When camera-side
        // sensor zoom is engaged (zoomFallbackActive == false), the body
        // already streams the sharp magnified frame, so we pass it straight
        // through, that's the whole point of the camera-side zoom path. We
        // only upscale-crop here if the body refused the eoszoom write.
        if zoomMode != .fit, zoomFallbackActive,
           let cropped = JPEGCrop.cropAt(jpeg, divisor: zoomMode.rawValue, center: meteringCenter) {
            jpeg = cropped
        }
        if focusPeakingEnabled,
           let peaked = FocusPeaking.apply(
               toJPEG: jpeg,
               mode: focusPeakingMode,
               intensity: Float(AppSettings.shared.focusPeakingIntensity),
               color: focusPeakingColor
           ) {
            jpeg = peaked
        }
        let base = NSImage(data: jpeg)
        // Draw the zoom box DIRECTLY INTO the frame (image-pixel space), not as
        // a separate SwiftUI overlay. This makes the box physically part of the
        // displayed image, so it can never drift from the image content the way
        // a floating overlay with its own geometry could, and since the zoom
        // maps from this same image space, the box and the zoomed region are
        // the same thing by construction. Drawn only at fit + while hovering.
        if let base, showMeteringOverlay, zoomMode == .fit {
            self.latestFrame = Self.drawZoomBox(on: base, center: meteringCenter,
                                                fraction: AppModel.zoomBoxFraction)
        } else {
            self.latestFrame = base
        }
    }

    /// Composite the zoom-target rectangle onto a copy of the frame in image
    /// pixel coordinates. `center` is normalized [0,1] top-down; NSImage's
    /// origin is bottom-left so we flip Y.
    private static func drawZoomBox(on image: NSImage, center: CGPoint, fraction f: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size))
        let bw = size.width * f, bh = size.height * f
        // Box is drawn at meteringCenter (already clamped to [f/2, 1-f/2] so it
        // reaches every edge and never goes off-screen). The constant offset
        // between box and where the camera zooms is applied in bodyZoomTopLeft
        // (zoom-side), so the box clamps cleanly here.
        let cx = center.x * size.width
        let cy = (1 - center.y) * size.height         // flip Y for AppKit coords
        let rect = CGRect(x: cx - bw/2, y: cy - bh/2, width: bw, height: bh)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = max(1.5, size.width / 480)  // ~2px at 1056-wide
        path.stroke()
        // small center crosshair
        let ch = NSBezierPath()
        ch.move(to: CGPoint(x: cx - 8, y: cy)); ch.line(to: CGPoint(x: cx + 8, y: cy))
        ch.move(to: CGPoint(x: cx, y: cy - 8)); ch.line(to: CGPoint(x: cx, y: cy + 8))
        ch.lineWidth = path.lineWidth; ch.stroke()
        out.unlockFocus()
        return out
    }

    // MARK: - Capture

    func captureNow() async {
        appLog.info("captureNow() called")
        guard let cap = capture else {
            appLog.error("captureNow: capture nil, connection not ready?")
            return
        }
        let folder = AppSettings.shared.captureFolder
        let pattern = AppSettings.shared.filenamePattern
        appLog.info("captureNow → \(folder.path, privacy: .public)/\(pattern, privacy: .public)")

        // The old gp_camera_capture path hung against EVF and so required a
        // pause/teardown/restart dance. The new eosremoterelease=Immediate
        // path inside CameraCapture honors the body's current LV+meter state
        //, capture happens with EVF UP, no mirror flap, no exposure shift.
        // That dance is gone. We DO still pause-via-priority through
        // withLVPriority so the capture's USB writes don't fight preview
        // frame fetches for the same wire.
        // Keep LV UP through capture. The previous EVF teardown forced the
        // body's REFLEX meter
        // (mirror down) to set capture exposure, which differed from the
        // LV preview (LV meter). EOS Utility doesn't drop the mirror; it
        // captures with LV up so the same sensor-based meter drives both
        // preview and captured exposure → they match.
        //
        // Historic concern: gp_camera_capture hung against viewfinder=1
        // on this body in earlier sessions. Re-testing fresh now that
        // C.Fn IV-1 is set. If it hangs/wedges, revert this block to
        // the lv.stop/lv.start dance.
        //
        // We DO still pause the LV frame fetch via withLVPriority (handled
        // inside cap.capture's caller, see kickMeter pattern) so the USB
        // pipe isn't fighting capture's writes.
        var captureResult: CameraCapture.CaptureResult?
        var captureError: Error?
        await withLVPriority {
            do {
                captureResult = try await cap.capture(to: folder, filenamePattern: pattern)
            } catch {
                captureError = error
            }
        }

        if let result = captureResult {
            self.lastCapture = result.path.lastPathComponent
            self.capturedFiles.append(contentsOf: result.allPaths)
            self.snapshot.iso = result.iso ?? self.snapshot.iso
            self.snapshot.shutter = result.shutter ?? self.snapshot.shutter
            self.snapshot.aperture = result.aperture ?? self.snapshot.aperture
            appLog.info("captureNow OK: \(result.path.lastPathComponent, privacy: .public)")
            // Pick up any side-effect property changes the camera made during
            // capture (focusmode auto-restored, AE state, etc).
            await refreshSnapshot()
        } else if let err = captureError as? CameraError {
            appLog.error("captureNow CameraError: \(err.localizedDescription, privacy: .public)")
            self.ui = .error(message: err.localizedDescription, hint: nil)
        } else if let err = captureError {
            appLog.error("captureNow error: \(String(describing: err), privacy: .public)")
            self.ui = .error(message: "\(err)", hint: nil)
        }
    }

    func triggerAutofocus() async {
        appLog.info("triggerAutofocus() called")
        guard let p = properties else { appLog.error("triggerAutofocus: properties nil"); return }
        // Wrap in LV-priority pause so the USB pipe is free for the AF
        // command. Without this the 30 FPS preview stream often hogs USB
        // and the body never sees a clean window for AF.
        await withLVPriority {
            do { try await p.triggerAutofocus() }
            catch let err as CameraError { appLog.error("triggerAutofocus: \(err.localizedDescription, privacy: .public)") }
            catch { appLog.error("triggerAutofocus: \(String(describing: error), privacy: .public)") }
        }
        await refreshSnapshot()
    }

    /// Push host *local* wall time → camera (TZ-aware). Used both by the auto-sync
    /// on connect and the explicit menu / footer click. Local-not-UTC because the
    /// 7D's EXIF DateTimeOriginal is a wall-clock value, UTC sync leaves a
    /// host_local - camera_local drift equal to the camera's TZ-vs-host-TZ
    /// offset (a 1-hour drift was observed with the camera set to PST while
    /// the host was in PDT). See CameraProperties for the
    /// detailed why.
    func syncCameraClockLocal() async {
        appLog.info("syncCameraClockLocal() called")
        guard let p = properties else { return }
        let tzOffset = AppSettings.shared.cameraTZOffsetMinutes
        do {
            try await p.syncDateTimeToHostLocal(tzOffsetMinutes: tzOffset)
            appLog.info("camera datetime synced (tzOffset=\(tzOffset, privacy: .public)min)")
            await refreshSnapshot()
        } catch let err as CameraError {
            appLog.error("syncCameraClockLocal failed: \(err.localizedDescription, privacy: .public)")
        } catch {
            appLog.error("syncCameraClockLocal failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Legacy menu hook, still wired in FilmTetherApp's commands for users who
    /// explicitly want UTC sync. New code calls syncCameraClockLocal directly.
    func syncCameraClock() async {
        await syncCameraClockLocal()
    }

    /// Background event drain. While connected we keep one in-flight call
    /// against gp_camera_wait_for_event with a short timeout, when the body
    /// emits property events (Tv changes from the auto-meter, lensname on
    /// attach, etc) we pick them up and update snapshot. This is the
    /// foundation of real-time metered Tv display in Av mode where the
    /// shutterspeed widget reads "auto" but the actual value comes through
    /// the event stream.
    private func startEventDrain() {
        eventDrainTask?.cancel()
        eventDrainTask = Task { [weak self] in
            await self?.runEventDrain()
        }
    }

    private func runEventDrain() async {
        guard let evts = cameraEvents else { return }
        appLog.info("event drain: starting")
        while !Task.isCancelled {
            // Yield to user-priority ops. When `withLVPriority` pauses the
            // LV runLoop, the same signal pauses us, otherwise we'd be
            // calling gp_camera_wait_for_event in parallel with capture's
            // waitForFileAdded and one consumer would eat the other's
            // events, causing "capture failed: timeout waiting for file
            // added" on every second shot. 50ms re-check feels instant
            // when the user op finishes.
            if let lv = liveView, await lv.isPaused {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            // drain() swallows errors internally. Loop only exits on
            // Task.isCancelled.
            let events = await evts.drain(budgetMs: 200, perCallMs: 100)
            if events.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            for evt in events {
                await applyEvent(evt)
            }
        }
        appLog.info("event drain: exited")
    }

    /// Project one camera event onto the UI snapshot. Most events just
    /// mirror what the body is doing internally; the one that matters
    /// for user-visible state is shutterspeed changes during metering.
    private func applyEvent(_ evt: CameraEvents.Event) async {
        switch evt {
        case .propertyChanged(let name, let value, _):
            guard let name, let value else { return }
            switch name {
            case "shutterspeed":
                let isAutoish = value.lowercased() == "auto" || value.isEmpty
                var s = self.snapshot
                if !isAutoish { s.meteredShutter = value }
                // In a manual exposure mode the picker should follow the body.
                // In Av/Tv/P the picker shows "auto", the metered value goes
                // into meteredShutter only.
                if s.mode.uppercased().contains("MANUAL") || s.mode.uppercased() == "M" {
                    s.shutter = value
                } else if isAutoish {
                    s.shutter = value  // picker shows whatever the body says
                }
                self.snapshot = s
                self.snapshotTick &+= 1
            case "iso":
                var s = self.snapshot
                s.iso = value
                self.snapshot = s
            case "aperture":
                var s = self.snapshot
                s.aperture = value
                self.snapshot = s
            // focusmode events are useful but PropertySnapshot doesn't surface
            // focusMode in the UI today, capture path just writes Manual/
            // One Shot directly. Skip rather than carry dead state.
            default:
                break
            }
        case .fileAdded, .captureComplete, .timeout, .unknown:
            // Capture path drains its own FILE_ADDED inside CameraCapture;
            // anything that arrives here was emitted while we weren't
            // actively capturing, safe to ignore.
            break
        }
    }

    /// Drop-flag so rapid manual-focus button mashing doesn't queue dozens of
    /// USB writes. Mashing once fired ~40 writes in 11 seconds and
    /// blocked a subsequent ISO change with -110 IO_IN_PROGRESS. When one
    /// drive is already in flight, additional presses are ignored, the
    /// motor on the body has a physical settle time anyway.
    private var manualFocusInFlight: Bool = false

    /// Drive manual focus by one step in the requested direction. Lens must
    /// be in AF mode on the lens switch AND body focusmode set to a non-Manual
    /// value for the motor to actually move, most USM lenses comply when both
    /// are set right. Watch the live view to confirm the lens moved.
    func driveManualFocus(_ step: CameraProperties.ManualFocusStep) async {
        if manualFocusInFlight {
            appLog.debug("driveManualFocus(\(step.rawValue, privacy: .public)) dropped, prior write still in flight")
            return
        }
        manualFocusInFlight = true
        defer { manualFocusInFlight = false }
        appLog.info("driveManualFocus(\(step.rawValue, privacy: .public))")
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.driveManualFocus(step)
                // Only advance the relative index once the body accepted the
                // drive, a thrown write leaves the counter untouched.
                self.focusStepPosition += step.weight
            }
            catch let err as CameraError { appLog.error("driveManualFocus: \(err.localizedDescription, privacy: .public)") }
            catch { appLog.error("driveManualFocus: \(String(describing: error), privacy: .public)") }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Reset the relative focus index to zero, the "you are here" origin the
    /// readout counts from. Does not move the lens.
    func resetFocusPosition() { focusStepPosition = 0 }

    /// Pause runLoop's frame fetching (via pauseCount), do the work, resume.
    /// Body state preserved, no mirror cycle, no focus loss. The AF cancel
    /// chaser in triggerAutofocus handles the body's AF-acquired state
    /// without needing a full LV teardown.
    ///
    /// If AF still wedges the body with just light pause + cancel, the AF
    /// button will be removed entirely (autofocus is optional).
    private func withLVPriority<T>(_ work: () async -> T) async -> T {
        guard let lv = liveView, isLiveViewOn else { return await work() }
        return await lv.withPriority { await work() }
    }

    func setMeteringMode(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setMeteringMode(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    /// Toggle 5× zoom mode latched (vs the momentary Space-hold). For the
    /// toolbar zoom button: button = toggle, Space = hold.
    func toggleZoom() async {
        if zoomMode == .fit {
            await applyZoom(.fivex)
        } else {
            await applyZoom(.fit)
        }
    }

    func setImageFormat(_ value: String) async {
        appLog.info("setImageFormat(\(value, privacy: .public)) called")
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setImageFormat(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    // MARK: - Property setters

    func setISO(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setIso(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
        // kickMeter() removed from settings-change path, Press Half writes
        // (even occasional) correlate with body wedges that need power-cycle.
    }

    func setShutter(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setShutter(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    func setAperture(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setAperture(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    func setWhiteBalanceKelvin(_ k: Int) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setWhiteBalanceKelvin(k)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    /// Start a periodic meter-kick task. Fires kickMeter() every ~2 seconds
    /// while LV is streaming so the footer's metered shutter updates even
    /// when the user is just sliding film (no settings changes to piggyback
    /// on). It re-meters every couple of seconds so sliding film alone still
    /// updates the meter.
    private func startMeterKick() {
        meterKickTask?.cancel()
        meterKickTask = Task { [weak self] in
            while !Task.isCancelled {
                // 2s cadence: fast enough that scene changes are visible
                // within ~2s; slow enough that the body isn't constantly
                // ticking AE locks. With C.Fn IV-1 = AE lock / AF, Press
                // Half is cheap, no AF noise, no mirror movement.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await self?.kickMeter()
            }
        }
    }

    /// Fire one Press Half / Release Half cycle to nudge the body's auto-meter
    /// into emitting the "what would capture meter" shutterspeed value. With
    /// C.Fn IV-1 = "AE lock / AF" on the body, this is just a brief AE lock
    /// (no AF noise, no extra mirror activity). The shutterspeed change event
    /// gets caught by runEventDrain → updates snapshot.meteredShutter →
    /// footer shows the capture-meter value. Without this, the LV meter and
    /// capture meter diverge and the footer can read 1/100 while capture
    /// fires 1/150.
    ///
    /// Best-effort: skipped silently if LV is off (no point) or if the
    /// widget writes fail. Only runs while connected + streaming.
    private func kickMeter() async {
        guard isLiveViewOn, let p = properties else { return }
        await withLVPriority {
            try? await p.setString("eosremoterelease", value: "Press Half")
            try? await Task.sleep(nanoseconds: 120_000_000)
            try? await p.setString("eosremoterelease", value: "Release Half")
        }
    }

    /// If we're showing a transient property-write error but the camera is
    /// otherwise healthy (still autodetecting / responding), clear the error
    /// so a subsequent successful write doesn't leave a stale message in the
    /// UI. We only clear .error → .ready; never touch .streaming/.disconnected.
    private func clearTransientErrorIfStreamingReady() {
        if case .error = ui {
            ui = .ready
        }
    }

    private func refreshSnapshot() async {
        guard let p = properties else { appLog.error("refreshSnapshot: properties nil"); return }
        // Single gp_camera_get_config call covers every leaf we display, much
        // gentler on the body than 6+ independent get_config calls per refresh.
        // Wrap in LV priority so this read doesn't compete with preview frames
        // when LV is active.
        let snap: CameraProperties.Snapshot? = await withLVPriority {
            do { return try await p.snapshot() }
            catch {
                appLog.error("snapshot read failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let snap else { return }
        var s = self.snapshot
        if let v = snap.iso          { s.iso = v }
        if let v = snap.shutter {
            s.shutter = v
            let isAutoish = v.lowercased() == "auto" || v.isEmpty || v == "—"
            if !isAutoish {
                s.meteredShutter = v
            }
        }
        if let v = snap.aperture     { s.aperture = v }
        if let v = snap.whiteBalance { s.whiteBalance = v }
        s.whiteBalanceKelvin = snap.kelvin ?? s.whiteBalanceKelvin
        if let v = snap.mode         { s.mode = v }
        if let v = snap.imageFormat  { s.imageFormat = v }
        if let v = snap.battery      { s.battery = v }
        if let v = snap.meteringMode { s.meteringMode = v }
        s.cameraDateTime = snap.cameraDateTime ?? s.cameraDateTime
        self.snapshot = s
        self.snapshotTick &+= 1
        appLog.info("snapshot[\(self.snapshotTick, privacy: .public)]: iso=\(s.iso, privacy: .public) Tv=\(s.shutter, privacy: .public) Av=\(s.aperture, privacy: .public) K=\(s.whiteBalanceKelvin ?? -1, privacy: .public) mode=\(s.mode, privacy: .public) fmt=\(s.imageFormat, privacy: .public) batt=\(s.battery, privacy: .public)")
    }

    private func loadChoices() async {
        guard let p = properties else { return }
        let cs: CameraProperties.ChoiceSet? = await withLVPriority {
            do { return try await p.choicesSnapshot() }
            catch {
                appLog.error("choices read failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let cs else { return }
        self.isoChoices = cs.iso
        self.shutterChoices = cs.shutter
        self.apertureChoices = cs.aperture
        self.imageFormatChoices = cs.imageFormat
        self.meteringModeChoices = cs.meteringMode
        appLog.info("choices: iso=\(cs.iso.count, privacy: .public) shutter=\(cs.shutter.count, privacy: .public) aperture=\(cs.aperture.count, privacy: .public) imageFormat=\(cs.imageFormat.count, privacy: .public) meteringMode=\(cs.meteringMode.count, privacy: .public)")
    }

    /// Periodic background refresh, picks up settings the user changes on the camera
    /// body. Cadence intentionally slow to minimize PTP pressure on the body.
    /// Post-wedge: when LV is active we DON'T refresh (the LV stream itself shows
    /// what the body's doing; we don't need redundant property polls). When idle
    /// we tick every 10s. Was 1s/3s before the wedge incident that needed AC pull.
    private func startSnapshotRefresh() {
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isStreaming = await MainActor.run { self.ui == .streaming }
                // Skip refresh entirely while LV is streaming, the body has
                // enough load just feeding 30 FPS preview. We rely on user
                // setting changes triggering their own refresh, and on the
                // post-action refreshSnapshot in captureNow / triggerAutofocus.
                // Idle cadence 10s (was 3s) so we put zero PTP pressure on a
                // body that's just sitting there.
                if isStreaming {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                let intervalNs: UInt64 = 10_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                let stillConnected = await MainActor.run {
                    if case .ready = self.ui { return true }
                    if case .streaming = self.ui { return true }
                    return false
                }
                guard stillConnected else { continue }
                await self.refreshSnapshot()
                // Reload choices every 4th tick, they change less often than values.
                if Int.random(in: 0..<4) == 0 {
                    await self.loadChoices()
                }
            }
        }
    }

    // MARK: - Hotkey

    private func startHotkey() {
        hotkey?.stop()
        hotkeyTask?.cancel()
        var config = HoldKeyMonitor.Config()
        if AppSettings.shared.zoomUsesShift {
            // Shift-hold = zoom. Bare modifier → always local;
            // a global Shift trigger would zoom while any app is focused.
            config.triggerModifier = .shift
            config.keyCode = 0x31 // unused for trigger; arrow-gate only
            config.globalScope = false
        } else {
            config.keyCode = AppSettings.shared.zoomKeyCode
            config.globalScope = AppSettings.shared.enableGlobalHotkey
        }
        hotkeyLog.info("starting HoldKeyMonitor (trigger=\(AppSettings.shared.zoomUsesShift ? "Shift" : "key0x\(String(config.keyCode, radix: 16))", privacy: .public), global=\(config.globalScope, privacy: .public))")
        let hk = HoldKeyMonitor(config: config)
        do {
            try hk.start()
            hotkeyLog.info("HoldKeyMonitor.start() OK")
        } catch {
            hotkeyLog.error("HoldKeyMonitor.start() failed: \(String(describing: error), privacy: .public)")
            return
        }
        self.hotkey = hk
        hotkeyTask = Task { [weak self] in
            for await event in hk.events {
                await self?.handleHotkey(event)
            }
        }
    }

    /// Local NSEvent monitor that fires capture on the configured capture key
    /// (default: Return). Only active while a Film Tether window is focused.
    private func startCaptureKeyMonitor() {
        if let monitor = captureKeyMonitor {
            NSEvent.removeMonitor(monitor)
            captureKeyMonitor = nil
        }
        let configured = AppSettings.shared.captureKeyCode
        hotkeyLog.info("installing capture-key monitor (keyCode=0x\(String(configured, radix: 16), privacy: .public))")
        captureKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Verbose: log every keyDown so we can see if the monitor is even firing.
            hotkeyLog.debug("keyDown: code=0x\(String(event.keyCode, radix: 16), privacy: .public) repeat=\(event.isARepeat, privacy: .public)")
            if event.isARepeat { return event }
            // Manual-focus stepping via keyboard: "," = far, "." = near.
            // Bare = fine (1), ⌥ = medium (2), ⌃ = coarse (3). ⌘ is left alone
            // so ⌘, still opens Settings. Only act over live view, and never
            // while a text field is being edited (Settings typing unaffected).
            if let chars = event.charactersIgnoringModifiers, chars == "," || chars == "." {
                if (NSApp.keyWindow?.firstResponder as? NSText) != nil { return event }
                let mods = event.modifierFlags
                if mods.contains(.command) { return event }
                guard self.isLiveViewOn else { return event }
                let near = (chars == ".")
                let step: CameraProperties.ManualFocusStep
                if mods.contains(.control)     { step = near ? .nearLarge : .farLarge }
                else if mods.contains(.option) { step = near ? .nearSmall : .farSmall }
                else                           { step = near ? .nearTiny  : .farTiny }
                hotkeyLog.info("focus key matched, driving \(step.rawValue, privacy: .public)")
                Task { await self.driveManualFocus(step) }
                return nil // consume
            }
            if event.keyCode == AppSettings.shared.captureKeyCode {
                hotkeyLog.info("capture key matched, firing captureNow")
                Task { await self.captureNow() }
                return nil // consume
            }
            return event
        }
    }

    private func handleHotkey(_ event: HoldKeyMonitor.Event) async {
        hotkeyLog.info("HoldKeyMonitor event: \(String(describing: event), privacy: .public)")
        switch event {
        case .pressed:
            // Trigger held (Shift by default) → punch in to 5× sensor zoom.
            // 10× was removed (silently no-ops on this 7D firmware).
            await applyZoom(.fivex)
        case .released:
            await applyZoom(.fit)
        case .arrow(let direction):
            // Arrow nudge moves the zoom rect by ONE FULL RECT STEP per
            // press (matches EOS Utility behavior). Now that zoom is
            // client-side (JPEG crop), the nudge is just a meteringCenter
            // shift, no body interaction, no calibration headaches.
            // Step = 0.2 normalized (1/5 of image dimension, matching the
            // 5x crop rect size). Clamped to [0.1, 0.9] so the rect never
            // crosses the edge.
            await nudgeMeteringCenter(direction)
        }
    }

    private func nudgeMeteringCenter(_ direction: HoldKeyMonitor.ArrowKey) async {
        let f = AppModel.zoomBoxFraction
        let step = f                 // one box-width per press
        let lo = f / 2, hi = 1 - f / 2   // keep the box fully inside the frame
        var c = meteringCenter
        switch direction {
        case .up:    c.y = max(lo, c.y - step)
        case .down:  c.y = min(hi, c.y + step)
        case .left:  c.x = max(lo, c.x - step)
        case .right: c.x = min(hi, c.x + step)
        }
        meteringCenter = c
        // If the real sensor zoom is engaged, move the punch-in to the new
        // spot too (arrows nudge the live magnified region, like EOS Utility).
        if zoomMode != .fit, !zoomFallbackActive, let lz = liveZoom {
            let (x, y) = bodyZoomTopLeft()
            self.zoomBodyCenter = (x, y)
            await withLVPriority { try? await lz.setZoomPosition(x: x, y: y) }
        }
    }

    private func applyZoom(_ mode: LiveZoom.Mode) async {
        self.zoomMode = mode
        // The goal is a zoom that yields more real pixels from the camera.
        // PRIMARY path is the body's sensor-crop punch-in (eoszoom), a fresh,
        // sharp 1024×680 JPEG of a
        // small sensor region, exactly what EOS Utility does. Client-side
        // JPEG crop is kept ONLY as an automatic fallback if the body refuses
        // the write. The box aims the punch-in via eoszoomposition.
        guard let lz = liveZoom else {
            self.zoomFallbackActive = true   // no camera-side path → client crop
            return
        }
        if mode == .fit {
            await withLVPriority { try? await lz.setZoom(.fit) }
            self.zoomFallbackActive = false
            return
        }
        // .fivex, punch in, THEN move the window to the box. Order matters:
        // Canon's EVF recenters the zoom window when zoom engages, so a
        // position written BEFORE eoszoom=5 is discarded (it doesn't zoom to
        // that spot). Enter magnified mode first, let the body settle,
        // then set eoszoomposition, and re-assert once, because the recenter
        // can land just after our first write.
        let (x, y) = bodyZoomTopLeft()
        self.zoomBodyCenter = (x, y)
        let cameraSideOK: Bool = await withLVPriority {
            do {
                try await lz.setZoom(.fivex)
                try? await Task.sleep(nanoseconds: 180_000_000)
                try await lz.setZoomPosition(x: x, y: y)
                try? await Task.sleep(nanoseconds: 120_000_000)
                try? await lz.setZoomPosition(x: x, y: y)
                return true
            } catch {
                appLog.error("camera-side zoom failed (\(String(describing: error), privacy: .public)); falling back to client crop")
                return false
            }
        }
        // OK → body now streams the magnified frame; handleFrame passes it
        // through untouched (sharp). Not OK → handleFrame client-crops.
        self.zoomFallbackActive = !cameraSideOK
    }

    /// Upper-left corner of the 1/5 punch-in rect in LV-image pixel space,
    /// derived from the normalized box center. `eoszoomposition` wants the
    /// top-left, not the center. Clamped so the rect stays inside the frame.
    private func bodyZoomTopLeft() -> (x: Int, y: Int) {
        // Desired rect top-left in OUTPUT pixels (the box you see), clamped so
        // the box stays in frame, then inverted through the measured line
        // fit_px = origin + eoszoom × slope to get the eoszoomposition value.
        // Invert the measured camera response: eoszoom = (box - offset) × gain,
        // clamped to the camera's range. Lands the zoom center on the box across
        // the reachable area; extreme top/left hit the hardware floor (eoszoom 0).
        let ex = (meteringCenter.x - AppModel.zoomRespOffset.x) * AppModel.zoomRespGain.x
        let ey = (meteringCenter.y - AppModel.zoomRespOffset.y) * AppModel.zoomRespGain.y
        let x = Int(min(max(ex, 0), AppModel.zoomEoszoomMax.x))
        let y = Int(min(max(ey, 0), AppModel.zoomEoszoomMax.y))
        return (x, y)
    }

    // nudgeZoom REMOVED, body refuses positions past a tight bound and
    // the EOS-Utility-style arrow stepping never traversed the full frame.

    // MARK: - Permissions

    func refreshPermissions() {
        self.permissionsState = .init(
            accessibility: Permissions.hasAccessibility,
            inputMonitoring: Permissions.hasInputMonitoring
        )
    }

    func requestAccessibility() { Permissions.requestAccessibility(); refreshPermissions() }
    func requestInputMonitoring() { Permissions.requestInputMonitoring(); refreshPermissions() }
    func openAccessibilityPane() { Permissions.openAccessibilityPane() }
    func openInputMonitoringPane() { Permissions.openInputMonitoringPane() }

    // MARK: - Re-entry after permission grant or first launch

    func enableGlobalHotkey() async {
        guard permissionsState.accessibility && permissionsState.inputMonitoring else { return }
        hotkey?.stop()
        hotkeyTask?.cancel()
        var config = HoldKeyMonitor.Config()
        config.keyCode = 0x31
        config.globalScope = true
        let hk = HoldKeyMonitor(config: config)
        do {
            try hk.start()
        } catch {
            // Permission was revoked between check and start. Leave hotkey nil.
            return
        }
        self.hotkey = hk
        hotkeyTask = Task { [weak self] in
            for await event in hk.events {
                await self?.handleHotkey(event)
            }
        }
    }
}
