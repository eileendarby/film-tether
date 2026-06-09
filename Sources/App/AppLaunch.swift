import Foundation
import Camera

/// Called once at process start before any libgphoto2 use.
enum AppLaunch {
    static let bootstrap: Void = {
        CameraEnvironment.setup()
        CameraLog.installGphotoLogBridge()  // no-op unless EOS_DEBUG=1
        CameraLog.session.info("Film Tether launched (debug=\(CameraLog.isDebug, privacy: .public))")
    }()
}
