import Foundation
import CGPhoto2

/// Drains libgphoto2's per-camera event queue and parses the strings Canon EOS
/// bodies emit on property changes. This is how we learn the body's *live*
/// metered exposure (Tv) during EVF streaming without polling, Canon's PTP
/// event channel pushes a `PTP Property d102 changed, "shutterspeed" to "1/200"`
/// line every time the meter recomputes.
///
/// Two consumers:
///   • CameraCapture's Immediate-release path drains `FILE_ADDED` events to
///     learn the on-camera filename after `eosremoterelease=Immediate`.
///   • AppModel runs a long-lived loop here while connected so the UI's
///     `meteredShutter` always reflects the body's most recent metering.
@CameraActor
public final class CameraEvents {
    /// One libgphoto2 event reduced to the bits we actually care about. Raw
    /// event payloads are kept inside this file, callers see typed values.
    public enum Event: Sendable, Equatable {
        /// No event during the timeout window. Caller loops on this.
        case timeout
        /// New file landed on the camera (Internal RAM or card). Folder + name
        /// are the on-camera path; CameraCapture downloads via gp_camera_file_get.
        case fileAdded(folder: String, name: String)
        /// A Canon property changed. `name` is libgphoto2's widget name when it
        /// resolved one (e.g. "shutterspeed", "iso", "aperture") and `value` is
        /// the new value as a string. `name` is nil when the property is one
        /// libgphoto2 doesn't have a mapping for (it shows as the raw hex code).
        case propertyChanged(name: String?, value: String?, raw: String)
        /// libgphoto2 fired GP_EVENT_CAPTURE_COMPLETE. We use this as a
        /// confirmation that the body finished writing a still even when we
        /// haven't yet seen FILE_ADDED.
        case captureComplete
        /// Anything we couldn't parse, kept so debug logs are honest.
        case unknown(raw: String)
    }

    private let session: CameraSession

    public init(session: CameraSession) {
        self.session = session
    }

    /// Block on `gp_camera_wait_for_event` for up to `timeoutMs` milliseconds,
    /// return the first event that arrives (or `.timeout`). Safe to call in a
    /// tight loop, libgphoto2 itself paces the underlying USB poll.
    ///
    /// Note: this is intentionally a *single* event per call. The body emits
    /// dozens of property events per second during EVF; we want to keep the
    /// loop in Swift land so the actor can yield between events.
    public func waitOne(timeoutMs: Int32) async throws -> Event {
        let cam = try session.gpCamera()
        let ctx = try session.gpContext()

        var eventType = CameraEventType(rawValue: 0)
        var eventData: UnsafeMutableRawPointer? = nil
        let rc = gp_camera_wait_for_event(cam, timeoutMs, &eventType, &eventData, ctx)
        if rc != GP_OK {
            // Bubble the error so the caller can decide whether to back off or
            // tear down. Most non-OK returns on this call mean the session
            // died (e.g. body powered off mid-stream), caller stops.
            throw CameraError.libGPhoto(
                code: rc,
                message: "gp_camera_wait_for_event failed (rc \(rc))"
            )
        }

        switch eventType {
        case GP_EVENT_TIMEOUT:
            return .timeout

        case GP_EVENT_FILE_ADDED:
            guard let raw = eventData else { return .timeout }
            // libgphoto2 hands us an allocated CameraFilePath* whose memory we
            // own. Copy folder + name into Swift, free the struct, return.
            let path = raw.assumingMemoryBound(to: CameraFilePath.self).pointee
            let folder = Self.cArrayToString(path.folder)
            let name = Self.cArrayToString(path.name)
            free(raw)
            return .fileAdded(folder: folder, name: name)

        case GP_EVENT_CAPTURE_COMPLETE:
            if eventData != nil { free(eventData) }
            return .captureComplete

        case GP_EVENT_UNKNOWN:
            guard let raw = eventData else { return .unknown(raw: "") }
            let s = String(cString: raw.assumingMemoryBound(to: CChar.self))
            free(raw)
            if let (name, value) = Self.parseUnknownPropertyChange(s) {
                return .propertyChanged(name: name, value: value, raw: s)
            }
            return .unknown(raw: s)

        case GP_EVENT_FOLDER_ADDED, GP_EVENT_FILE_CHANGED:
            // Neither matters for our flows, folder-added is the camera
            // creating a new DCIM subdir, file-changed is metadata-only.
            if eventData != nil { free(eventData) }
            return .timeout

        default:
            if eventData != nil { free(eventData) }
            return .unknown(raw: "type=\(eventType.rawValue)")
        }
    }

    /// Drain all queued events with a per-call timeout, up to `budgetMs`
    /// wall-clock milliseconds total. Used for "give me everything that's
    /// been sitting in the queue right now without blocking long." Returns
    /// the events in arrival order; never throws timeout (caller sees an
    /// empty array if the queue was empty when the budget started).
    public func drain(budgetMs: Int, perCallMs: Int32 = 50) async -> [Event] {
        let deadline = Date().addingTimeInterval(TimeInterval(budgetMs) / 1000.0)
        var out: [Event] = []
        while Date() < deadline {
            let remaining = max(0, Int32(deadline.timeIntervalSinceNow * 1000.0))
            let thisCall = min(perCallMs, remaining > 0 ? remaining : 1)
            do {
                let e = try await waitOne(timeoutMs: thisCall)
                if case .timeout = e { break }
                out.append(e)
            } catch {
                // Session error inside drain, caller's outer loop will
                // notice on the next session probe; bail out here.
                break
            }
        }
        return out
    }

    // MARK: - Parsing

    /// Canon EOS firmware emits unknown-event strings like:
    ///   `PTP Property d102 changed, "shutterspeed" to "1/200"`
    ///   `PTP Property d101 changed`
    /// Return (name, value) when both are present; (name, nil) when libgphoto2
    /// resolved the property name but the value didn't quote; nil when the
    /// whole line is something else (Focus Points, CTGInfoCheckComplete, …).
    static func parseUnknownPropertyChange(_ s: String) -> (String, String?)? {
        guard s.contains("PTP Property") else { return nil }
        // Strip prefix; split on `, "name" to "value"` if present.
        if let quoteRange = s.range(of: "\""),
           let afterFirst = s.range(of: "\" to \"") {
            let nameStart = quoteRange.upperBound
            let nameEnd = afterFirst.lowerBound
            guard nameStart < nameEnd else { return nil }
            let name = String(s[nameStart..<nameEnd])
            let valueStart = afterFirst.upperBound
            // Find the closing quote of the value.
            guard let closing = s.range(of: "\"", range: valueStart..<s.endIndex) else {
                return (name, nil)
            }
            let value = String(s[valueStart..<closing.lowerBound])
            return (name, value)
        }
        // Form 2: `"name" changed`, name only, no value.
        if let first = s.range(of: "\""),
           let second = s.range(of: "\"", range: first.upperBound..<s.endIndex) {
            let name = String(s[first.upperBound..<second.lowerBound])
            return (name, nil)
        }
        return nil
    }

    /// libgphoto2 fixed-size char arrays surface in Swift as tuples of
    /// (CChar, CChar, …). Decode via raw memory, same trick CameraCapture
    /// uses for filePath.folder / filePath.name.
    private static func cArrayToString<T>(_ tuple: T) -> String {
        return withUnsafePointer(to: tuple) { ptr -> String in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
    }
}
