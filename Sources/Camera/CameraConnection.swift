import Foundation
import CGPhoto2

/// USB enumeration + reconnection state machine. Polls libgphoto2's `gp_camera_autodetect`
/// (no hotplug API in libgphoto2 itself), claims/releases macOS's PTP layer around `open()`,
/// publishes state via `stateStream`. Matches any Canon EOS body, tested with 7D + 70D.
@CameraActor
public final class CameraConnection {
    public enum ConnectionState: Sendable, Equatable {
        case disconnected
        case enumerating
        case ready
        case error(String) // CameraError.errorDescription
    }

    public nonisolated let stateStream: AsyncStream<ConnectionState>
    private nonisolated let continuation: AsyncStream<ConnectionState>.Continuation

    private var session: CameraSession?
    private var monitorTask: Task<Void, Never>?
    private var lastState: ConnectionState = .disconnected
    private var consecutiveMisses: Int = 0
    private var connectInFlight: Bool = false
    private let missesBeforeDisconnect = 3
    // Poll the USB bus at 10-second cadence, minimal pressure on the body.
    // Increased from 3s after a 7D wedged so deeply it required a full
    // AC pull to recover. Once connected we don't NEED frequent autodetect;
    // it's only useful for hot-plug detection, and post-wedge the body is
    // fragile enough that even autodetect's USB enumeration can stress it.
    private let pollIntervalNanoseconds: UInt64 = 10_000_000_000 // 10s

    public init() {
        var localContinuation: AsyncStream<ConnectionState>.Continuation!
        self.stateStream = AsyncStream<ConnectionState> { cont in
            localContinuation = cont
        }
        self.continuation = localContinuation
    }

    deinit {
        monitorTask?.cancel()
        continuation.finish()
    }

    public func startMonitoring() async {
        guard monitorTask == nil else { return }
        let interval = pollIntervalNanoseconds
        monitorTask = Task { @CameraActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    public func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        if let s = session { s.close() }
        session = nil
        transition(.disconnected)
    }

    public func currentSession() -> CameraSession? {
        return session
    }

    // MARK: - Private

    private func tick() async {
        // Skip the entire tick if a connect() is mid-flight. The sleeps inside
        // ICDeviceClaim.releaseCanonEos (~2s) + gp_camera_init (variable) can outlast
        // the 1s poll interval; re-entrancy here would cause flapping UI states.
        guard !connectInFlight else { return }

        let present = await isCanonEosPresent()
        if present {
            consecutiveMisses = 0
            if session == nil {
                await connect()
            }
        } else {
            consecutiveMisses += 1
            if consecutiveMisses >= missesBeforeDisconnect, session != nil {
                session?.close()
                session = nil
                transition(.disconnected)
            }
        }
    }

    /// Scan via `gp_camera_autodetect` for any Canon EOS body.
    /// Tested with the 7D and 70D; should work with any Canon EOS body that libgphoto2
    /// supports (which is essentially the whole product line). We filter by name here
    /// rather than USB ID because the libgphoto2 enumeration doesn't easily expose USB IDs;
    /// the per-body USB-claim release uses Canon's vendor ID via ImageCaptureCore.
    private func isCanonEosPresent() async -> Bool {
        var list: OpaquePointer? = nil
        guard gp_list_new(&list) == GP_OK, let list else { return false }
        defer { gp_list_unref(list) }

        // gp_camera_autodetect needs its own short-lived context.
        let ctx = gp_context_new()
        defer { if let ctx { gp_context_unref(ctx) } }
        guard let ctx else { return false }

        let count = gp_camera_autodetect(list, ctx)
        guard count > 0 else { return false }

        for i in 0..<Int32(count) {
            var name: UnsafePointer<CChar>? = nil
            if gp_list_get_name(list, i, &name) == GP_OK, let name {
                let s = String(cString: name)
                CameraLog.connection.debug("autodetect candidate: \(s, privacy: .public)")
                // Match any Canon EOS body. libgphoto2 names them like "Canon EOS 7D",
                // "Canon EOS 70D", "Canon EOS 5D Mark IV", etc.
                if s.localizedCaseInsensitiveContains("Canon EOS") {
                    CameraLog.connection.info("autodetect matched: \(s, privacy: .public)")
                    return true
                }
            }
        }
        return false
    }

    private func connect() async {
        connectInFlight = true
        defer { connectInFlight = false }
        transition(.enumerating)

        // Gentle-first strategy (D24 finding): without ImageCaptureCore in our process
        // ptpcamerad doesn't preemptively grab the USB, so a clean `gp_camera_init` on
        // first try usually wins. Skipping the killall + eject on attempt 1 avoids
        // disturbing the camera unnecessarily, those are reserved for the retry path
        // when the first attempt actually fails with -53/-105 (USB-claim race).
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            if attempt > 1 {
                CameraLog.connection.info("retry attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public): killing ptpcamerad")
                ICDeviceClaim.killPTPCameraHelper()
                if attempt >= 3 {
                    CameraLog.connection.info("attempt \(attempt, privacy: .public): also ICDevice eject")
                    await ICDeviceClaim.releaseCanonEos()
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            do {
                CameraLog.connection.info("opening CameraSession (attempt \(attempt, privacy: .public))")
                let s = try CameraSession()
                try await s.open()
                self.session = s
                transition(.ready)
                return
            } catch let err as CameraError {
                lastError = err
                let isRecoverable: Bool = {
                    if case .usbClaimDenied = err { return true }
                    if case .libGPhoto(let code, _) = err {
                        // -53 IO_USB_CLAIM, -105 MODEL_NOT_FOUND (post-half-claim), -52 IO
                        return code == -53 || code == -105 || code == -52
                    }
                    return false
                }()
                if isRecoverable && attempt < maxAttempts {
                    // Escalating back-off: 0.5s, 1s, 2s, 3s between attempts.
                    let backoffMs = attempt * 500
                    CameraLog.connection.error("attempt \(attempt, privacy: .public): \(err.localizedDescription, privacy: .public), backing off \(backoffMs, privacy: .public)ms before retry")
                    try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                    continue
                }
                CameraLog.connection.error("connect failed (CameraError, final): \(err.localizedDescription, privacy: .public)")
                transition(.error(err.localizedDescription))
                return
            } catch {
                lastError = error
                CameraLog.connection.error("connect failed (other, final): \(String(describing: error), privacy: .public)")
                transition(.error("\(error)"))
                return
            }
        }
        let msg = lastError.map { "\($0)" } ?? "unknown"
        transition(.error(msg))
    }

    private func transition(_ new: ConnectionState) {
        if new == self.lastState { return }
        let prev = self.lastState
        CameraLog.connection.info("state: \(String(describing: prev), privacy: .public) → \(String(describing: new), privacy: .public)")
        self.lastState = new
        self.continuation.yield(new)
    }
}
