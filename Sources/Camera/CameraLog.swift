import Foundation
import os
import CGPhoto2

/// Central logging surface for the Camera module.
///
/// All logs go to macOS unified logging under subsystem `co.wonders.filmtether`,
/// streamable via:
///
///     log stream --predicate 'subsystem == "co.wonders.filmtether"' --info --debug
///
/// Set the env var `EOS_DEBUG=1` before launching the app (or use `make run-debug`)
/// to enable verbose mode: every libgphoto2 internal log message is bridged into our
/// system stream, and `.debug` messages from our own code are emitted (otherwise they
/// drop). Errors and high-level state changes are always logged regardless of debug.
public enum CameraLog {
    private static let subsystem = "co.wonders.filmtether"

    public static let connection = Logger(subsystem: subsystem, category: "Connection")
    public static let session = Logger(subsystem: subsystem, category: "Session")
    public static let properties = Logger(subsystem: subsystem, category: "Properties")
    public static let capture = Logger(subsystem: subsystem, category: "Capture")
    public static let liveView = Logger(subsystem: subsystem, category: "LiveView")
    public static let liveZoom = Logger(subsystem: subsystem, category: "LiveZoom")
    public static let icDevice = Logger(subsystem: subsystem, category: "ICDevice")
    public static let gphoto = Logger(subsystem: subsystem, category: "gphoto2")

    public static var isDebug: Bool {
        ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1"
    }

    /// One-time install of a libgphoto2 log callback that pipes its internal logging
    /// into our unified-log stream. Called from `AppLaunch.bootstrap`.
    public static func installGphotoLogBridge() {
        guard isDebug else { return }
        // GP_LOG_DATA = everything (very verbose). For less noise, use GP_LOG_DEBUG.
        gp_log_add_func(GP_LOG_DEBUG, { level, domain, message, _ in
            let d = domain.map { String(cString: $0) } ?? "?"
            let m = message.map { String(cString: $0) } ?? "?"
            switch level {
            case GP_LOG_ERROR:
                CameraLog.gphoto.error("[\(d, privacy: .public)] \(m, privacy: .public)")
            case GP_LOG_VERBOSE:
                CameraLog.gphoto.info("[\(d, privacy: .public)] \(m, privacy: .public)")
            case GP_LOG_DEBUG:
                CameraLog.gphoto.debug("[\(d, privacy: .public)] \(m, privacy: .public)")
            case GP_LOG_DATA:
                CameraLog.gphoto.debug("[\(d, privacy: .public)] \(m, privacy: .public)")
            default:
                CameraLog.gphoto.debug("[\(d, privacy: .public)] \(m, privacy: .public)")
            }
        }, nil)
        CameraLog.gphoto.info("EOS_DEBUG=1, libgphoto2 log bridge installed (level=DEBUG)")
    }
}
