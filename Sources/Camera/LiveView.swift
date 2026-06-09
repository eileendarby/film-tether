import Foundation
import CGPhoto2

/// Polls `gp_camera_capture_preview` continuously to deliver live-view JPEG frames.
@CameraActor
public final class LiveView {
    public struct Frame: Sendable {
        public let jpegData: Data
        public let timestamp: Date
        public let width: Int?
        public let height: Int?
    }

    public nonisolated let frameStream: AsyncStream<Frame>
    private nonisolated let continuation: AsyncStream<Frame>.Continuation

    private let session: CameraSession
    private let properties: CameraProperties
    private var loopTask: Task<Void, Never>?
    /// Tracks the in-flight setViewfinder(false) from a previous stop(). The
    /// next start() awaits it so we can't race a delayed EVF-off into a fresh
    /// EVF-on. Without this guard the symptom is "Start Live View stops working
    /// after the first stop" because the stale stop wins the actor race and
    /// writes viewfinder=0 right after start() wrote viewfinder=1.
    private var pendingStopTask: Task<Void, Never>?
    public private(set) var isActive: Bool = false
    /// Pause counter for the frame loop. When > 0, runLoop yields the actor
    /// and waits instead of fetching a frame. User actions (AF, focus drive,
    /// property writes) increment this before doing their USB work and
    /// decrement after, guaranteeing the LV stream doesn't compete for the
    /// USB pipe while the body is processing a user request. Without this,
    /// pressing AF / focus / ISO either did nothing or returned -110 errors
    /// because the 30 FPS LV traffic left no breathing room.
    private var pauseCount: Int = 0

    public init(session: CameraSession, properties: CameraProperties) {
        self.session = session
        self.properties = properties
        var localContinuation: AsyncStream<Frame>.Continuation!
        self.frameStream = AsyncStream<Frame>(bufferingPolicy: .bufferingNewest(2)) { cont in
            localContinuation = cont
        }
        self.continuation = localContinuation
    }

    deinit {
        loopTask?.cancel()
        continuation.finish()
    }

    public func start() async throws {
        guard !isActive else { return }
        // Critical: drain the in-flight stop's setViewfinder(false) BEFORE
        // we write viewfinder=1, or the stale stop wins the actor race and
        // turns the EVF right back off after we just turned it on. This is
        // why "Start Live View" silently failed on the 2nd+ press.
        if let pending = pendingStopTask {
            CameraLog.liveView.info("start: awaiting pending stop's setViewfinder(false) to complete")
            _ = await pending.value
            pendingStopTask = nil
        }
        CameraLog.liveView.info("start: requesting PC live view")
        // First: route frames to the host (not HDMI). 'output' is on the 7D + similar bodies;
        // newer EOS may not expose it.
        try? await setOutputToPC()
        // Then: toggle the viewfinder leaf. Try 'viewfinder' first (7D + most EOS bodies);
        // fall back to 'eosviewfinder' (some newer bodies expose only that virtual leaf).
        try await setViewfinder(enabled: true)
        // Enable exposure simulation so the LV preview brightness matches what
        // the captured image will look like. Without this, the 7D shows an
        // auto-gain'd preview regardless of exposure settings, causing the
        // "captured image is much brighter than the live view" symptom.
        // Best-effort: skips silently if the widget isn't exposed on this body.
        try? await properties.setExposureSimulation(true)
        // Kick the body's auto-meter loop. Without this the 7D firmware
        // doesn't emit shutterspeed change events during LV until SOMETHING
        // wakes the metering state machine, which is why the footer stays
        // blank until first capture.
        //
        // SAFETY: this was removed earlier because it wedged the body when
        // C.Fn IV-1 was at default ("Shutter / AE lock"). On that setting,
        // Press Half drove AF, and AF-during-LV-startup correlates with the
        // firmware-deep wedge. With C.Fn IV-1 = "AE lock / AF", Press Half =
        // AE lock only, no AF. The hazardous interaction is gone.
        //
        // Body behavior after this kick: Press Half locks AE for ~120ms,
        // Release Half returns the body to "LV with auto-meter active"
        // state. Subsequent shutterspeed change events flow as the scene
        // changes brightness. If users hit a regression, flip C.Fn IV-1
        // back and we won't fire this kick (TODO: detect via customfuncex
        // read; for now, document).
        try? await properties.setString("eosremoterelease", value: "Press Half")
        try? await Task.sleep(nanoseconds: 120_000_000)
        try? await properties.setString("eosremoterelease", value: "Release Half")
        isActive = true
        loopTask = Task { @CameraActor [weak self] in
            await self?.runLoop()
        }
        CameraLog.liveView.info("start: loop task spawned")
    }

    public func stop() async throws {
        guard isActive else { return }
        CameraLog.liveView.info("stop: cancelling loop")
        isActive = false
        loopTask?.cancel()
        loopTask = nil
        // Full EVF teardown for the 7D: write BOTH viewfinder=0 (EVFMode) AND
        // output=TFT (EVFOutputDevice) so the mirror actually drops. Done
        // SYNCHRONOUSLY (awaited), this used to be spawned as a background task,
        // which let app-quit run gp_camera_exit BEFORE the mirror dropped,
        // wedging the body until a power-cycle (closing the app without
        // stopping live view broke the body). Awaiting guarantees mirror-down
        // before the caller (quit's gp_camera_exit, or a re-start) proceeds.
        do {
            try await setViewfinder(enabled: false)
            CameraLog.liveView.info("stop: setViewfinder(false) wrote")
        } catch {
            CameraLog.liveView.error("stop: setViewfinder(false) failed: \(String(describing: error))")
        }
        do {
            try await setOutputToTFT()
            CameraLog.liveView.info("stop: setOutputToTFT wrote (mirror should drop)")
        } catch {
            CameraLog.liveView.info("stop: setOutputToTFT skipped: \(String(describing: error))")
        }
    }

    /// True iff a user-priority op is currently holding the pipe via
    /// withPriority. Exposed so other background loops (e.g. AppModel's
    /// event-drain task) can pause themselves on the same signal, capture
    /// can't have a second `gp_camera_wait_for_event` consumer running
    /// while it waits for FILE_ADDED, or that other consumer eats the
    /// event the capture needs.
    public var isPaused: Bool { pauseCount > 0 }

    /// Increment the pause counter. The runLoop will yield instead of
    /// fetching until a matching `resumeFrameLoop()` decrements back to 0.
    /// Safe to nest (counter handles overlapping user ops). Cheap: just
    /// flips an Int on the actor, no USB transaction.
    public func pauseFrameLoop() async {
        pauseCount += 1
    }

    /// Decrement the pause counter. Once it returns to 0 the runLoop's
    /// next iteration resumes fetching.
    public func resumeFrameLoop() async {
        pauseCount = Swift.max(0, pauseCount - 1)
    }

    /// Run a closure with the frame loop paused. The pause is incremented
    /// before the closure runs and decremented after, even on throw. Used
    /// by AppModel to wrap every user-initiated camera op (set ISO, AF,
    /// manual focus drive, etc) so the LV stream gets out of the way.
    public func withPriority<T>(_ work: () async throws -> T) async rethrows -> T {
        await pauseFrameLoop()
        defer { Task { await self.resumeFrameLoop() } }
        CameraLog.liveView.info("withPriority: paused (count=\(self.pauseCount, privacy: .public))")
        // 100ms settle (was 500ms). The 500ms originated from the
        // mirror-cycling capture path that doesn't apply anymore now that
        // LV stays up through capture. The body's
        // libgphoto2 port still wants a tiny breath between the LV fetch
        // tail and our user op; 100ms is empirically enough.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let result = try await work()
        CameraLog.liveView.info("withPriority: work completed")
        return result
    }

    /// One-shot fetch of a single preview frame. Callers see CameraError on
    /// any libgphoto2 error AND on host-side timeout: `gp_camera_capture_preview`
    /// has been observed hanging 20+ seconds before returning -7 when the body
    /// is in certain wedged states. The host-side timeout lets the app
    /// surface "body unresponsive" instead of appearing frozen.
    public func fetchOnePreview() async throws -> Data {
        return try await fetchOnePreviewWithTimeout(seconds: 5)
    }

    private func fetchOnePreviewWithTimeout(seconds: Double) async throws -> Data {
        // Race the actual fetch against a deadline timer. Whichever finishes
        // first wins; the loser is cancelled. The C call inside fetchRaw
        // can't be cancelled from Swift, but throwing here at least
        // unblocks the caller so the runLoop can decide what to do next
        // (back off, surface an error, etc).
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { @CameraActor in
                try await self.fetchOnePreviewRaw()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CameraError.libGPhoto(
                    code: -10,
                    message: "fetchOnePreview timed out after \(seconds)s, body may be wedged"
                )
            }
            // First child to finish supplies the result; cancel the rest.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func fetchOnePreviewRaw() async throws -> Data {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        var file: OpaquePointer? = nil
        try CameraError.check(gp_file_new(&file))
        guard let file else { throw CameraError.captureFailed(reason: "gp_file_new failed") }
        defer { gp_file_unref(file) }
        try CameraError.check(gp_camera_capture_preview(cam, file, ctx))
        var dataPtr: UnsafePointer<CChar>? = nil
        var size: UInt = 0
        try withUnsafeMutablePointer(to: &dataPtr) { dPtr in
            try withUnsafeMutablePointer(to: &size) { sPtr in
                try CameraError.check(gp_file_get_data_and_size(file, dPtr, sPtr))
            }
        }
        guard let dataPtr, size > 0 else {
            throw CameraError.captureFailed(reason: "empty preview data")
        }
        return Data(bytes: dataPtr, count: Int(size))
    }

    // MARK: - Private

    /// Toggle the live-view feed on or off. Tries `viewfinder` (the actual leaf on the
    /// 7D, 70D, and most EOS bodies) first; falls back to `eosviewfinder` for newer
    /// bodies where libgphoto2 exposes only that virtual leaf.
    private func setViewfinder(enabled: Bool) async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        for name in ["viewfinder", "eosviewfinder"] {
            do {
                let (root, leaf) = try WidgetHelpers.resolveLeaf(
                    camera: cam, context: ctx, name: name
                )
                defer { gp_widget_unref(root) }
                try WidgetHelpers.writeToggle(leaf, value: enabled ? 1 : 0)
                try WidgetHelpers.commit(camera: cam, context: ctx, name: name, leaf: leaf)
                CameraLog.liveView.info("setViewfinder(\(enabled, privacy: .public)): wrote leaf '\(name, privacy: .public)'")
                return
            } catch CameraError.propertyNotFound {
                continue // try next name
            }
        }
        CameraLog.liveView.error("setViewfinder: neither 'viewfinder' nor 'eosviewfinder' exists on this body")
        throw CameraError.propertyNotFound(name: "viewfinder/eosviewfinder")
    }

    /// Route live-view frames over USB to the host (vs HDMI to a TV). The 7D and similar
    /// bodies expose this under `/main/settings/output`. Best-effort: if the leaf isn't
    /// present, we skip silently (newer bodies use viewfinder alone).
    private func setOutputToPC() async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "output"
        )
        defer { gp_widget_unref(root) }
        // The 'output' leaf's options vary by body. The 7D's choices are typically
        // "TFT", "PC", "MOBILE", "MOBILE2", "OFF". Setting "PC" routes USB-bound frames.
        try WidgetHelpers.writeString(leaf, value: "PC")
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "output", leaf: leaf)
        CameraLog.liveView.info("setOutputToPC: output=PC")
    }

    /// Restore `output` to the camera's default (TFT = on-camera LCD). This is the
    /// other half of the EVF teardown that libgphoto2's library.c camera_stop_preview
    /// does, writing EVFOutputDevice back so the body drops the mirror and exits
    /// the live-view state machine. Without this the 7D leaves the mirror up.
    private func setOutputToTFT() async throws {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()
        let (root, leaf) = try WidgetHelpers.resolveLeaf(
            camera: cam, context: ctx, name: "output"
        )
        defer { gp_widget_unref(root) }
        // Try "TFT" first (the 7D's standard label); fall back to "OFF" for
        // bodies that expose that instead. We pass whichever string libgphoto2's
        // choice list exposes, set_value will error if the value isn't in the
        // enum, which is caught by the caller as non-fatal.
        do {
            try WidgetHelpers.writeString(leaf, value: "TFT")
        } catch {
            try WidgetHelpers.writeString(leaf, value: "OFF")
        }
        try WidgetHelpers.commit(camera: cam, context: ctx, name: "output", leaf: leaf)
    }

    private func runLoop() async {
        var consecutiveErrors = 0
        var frameCount = 0
        // EVF needs time to settle after viewfinder=1; the first few
        // gp_camera_capture_preview calls often return -110 I/O in progress
        // (or -1 General Error if body hasn't engaged EVF yet) while the
        // mirror flips and the JPEG pipeline initializes. The 7D from a
        // cold start needs ~1s. Earlier 400ms was sometimes too short.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        CameraLog.liveView.info("runLoop: starting fetch loop (target ~30 FPS)")
        // Frame-rate cap. The 7D + libgphoto2 will deliver ~30-40 FPS uncapped,
        // which matches the body's internal EVF refresh, no heat or wear risk,
        // it's the same sensor read-out. But 30 FPS is what EOS Utility uses for
        // tethered live view on this body, and capping reduces USB chatter and
        // host CPU without losing visible smoothness. Photographer-friendly.
        let targetFrameInterval: UInt64 = 33_000_000  // 33ms = ~30 FPS
        while !Task.isCancelled && isActive {
            // Yield to user-priority ops. While the pause counter is non-zero,
            // skip fetching and just sleep, the body's USB pipe belongs to
            // whatever user action (AF, focus drive, ISO change) incremented
            // the counter. We re-check every 50ms; user ops typically take
            // 100-300ms so this loop won't burn the actor.
            if pauseCount > 0 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            let frameStart = DispatchTime.now()
            do {
                let bytes = try await fetchOnePreview()
                let (w, h) = Self.parseJPEGDimensions(bytes)
                let frame = Frame(jpegData: bytes, timestamp: Date(), width: w, height: h)
                continuation.yield(frame)
                if frameCount == 0 {
                    CameraLog.liveView.info("runLoop: first frame yielded (\(bytes.count) bytes, \(w ?? 0)x\(h ?? 0))")
                }
                frameCount += 1
                if frameCount % 30 == 0 {
                    CameraLog.liveView.debug("runLoop: \(frameCount) frames yielded")
                }
                consecutiveErrors = 0
                // Yield the CameraActor between frames so property writes, capture,
                // and zoom calls don't have to wait for the next preview tick. Also
                // pace to ~30 FPS, sleep the remainder of the target interval. If
                // the fetch already took longer than the interval we proceed
                // immediately (no negative sleep).
                let elapsed = DispatchTime.now().uptimeNanoseconds - frameStart.uptimeNanoseconds
                if elapsed < targetFrameInterval {
                    try? await Task.sleep(nanoseconds: targetFrameInterval - elapsed)
                } else {
                    await Task.yield()
                }
            } catch {
                consecutiveErrors += 1
                // privacy: .public so we can actually SEE what's failing, os_log
                // censors String(describing:) by default, which made the
                // body-not-engaging-EVF issue undiagnosable.
                CameraLog.liveView.error("runLoop: fetch error #\(consecutiveErrors, privacy: .public), \(String(describing: error), privacy: .public)")
                // Bumped from 3 -> 25; -110 I/O in progress is normal during
                // mirror flip and camera-side state transitions. Backoff longer
                // each time so we don't hammer libgphoto2's port.
                if consecutiveErrors >= 25 {
                    CameraLog.liveView.error("runLoop: 25 consecutive errors, giving up")
                    continuation.finish()
                    isActive = false
                    return
                }
                let backoff: UInt64 = min(2_000_000_000, UInt64(consecutiveErrors) * 200_000_000)
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
        CameraLog.liveView.info("runLoop: exited (cancelled=\(Task.isCancelled), isActive=\(self.isActive), frames=\(frameCount))")
    }

    /// Parse SOF0 (Start of Frame, baseline DCT) marker from a JPEG to extract dimensions.
    /// Returns (nil, nil) if not found. Public + static for testability.
    public static func parseJPEGDimensions(_ data: Data) -> (Int?, Int?) {
        guard data.count >= 4 else { return (nil, nil) }
        // JPEG must start with FF D8.
        guard data[0] == 0xFF, data[1] == 0xD8 else { return (nil, nil) }
        var i = 2
        while i < data.count - 8 {
            // Markers start with 0xFF; skip fill bytes.
            guard data[i] == 0xFF else { i += 1; continue }
            // Skip 0xFF 0x00 (stuffed byte inside scan data, but we should have exited at SOS).
            let marker = data[i + 1]
            if marker == 0xD8 || marker == 0xD9 { i += 2; continue }
            // SOF0 = 0xC0 .. SOF15 = 0xCF except DHT (0xC4), JPG (0xC8), DAC (0xCC).
            if (marker >= 0xC0 && marker <= 0xCF) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                guard i + 9 < data.count else { return (nil, nil) }
                let h = (Int(data[i + 5]) << 8) | Int(data[i + 6])
                let w = (Int(data[i + 7]) << 8) | Int(data[i + 8])
                return (w, h)
            }
            // Standard segment: 2-byte length follows the marker.
            guard i + 3 < data.count else { return (nil, nil) }
            let segmentLen = (Int(data[i + 2]) << 8) | Int(data[i + 3])
            if segmentLen < 2 { return (nil, nil) }
            i += 2 + segmentLen
        }
        return (nil, nil)
    }
}
