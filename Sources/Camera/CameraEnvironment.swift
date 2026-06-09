import Foundation

/// One-time process setup for libgphoto2's `dlopen` search paths.
///
/// libgphoto2 dynamically loads camlibs (e.g. `libcanon.so`, `libptp2.so`) and iolibs
/// (e.g. `libusb1.so`) at `gp_camera_init` time. The default search path is the
/// compile-time prefix of whatever libgphoto2 binary we linked, for a Homebrew install
/// that's `/opt/homebrew/Cellar/libgphoto2/.../lib/libgphoto2/...`. That path embeds a
/// brew version number that drifts on `brew upgrade`, so the bundled app would break
/// silently after an unrelated brew operation.
///
/// To keep the .app self-contained, the bundle script copies the camlibs and iolibs into
/// `Contents/Resources/camlibs/` and `Contents/Resources/iolibs/` and we override the
/// search via the `CAMLIBS` / `IOLIBS` env vars before any libgphoto2 call.
public enum CameraEnvironment {
    private static let setupOnce: Void = {
        guard let resources = Bundle.main.resourcePath else { return }
        let camlibs = "\(resources)/camlibs"
        let iolibs = "\(resources)/iolibs"
        // Only override if the directory actually exists in the bundle, during `swift run`
        // (no app bundle) we fall back to the compile-time default (brew prefix).
        if FileManager.default.fileExists(atPath: camlibs) {
            setenv("CAMLIBS", camlibs, 1)
        }
        if FileManager.default.fileExists(atPath: iolibs) {
            setenv("IOLIBS", iolibs, 1)
        }
    }()

    /// Idempotent and thread-safe (backed by Swift's static-let-once init).
    public static func setup() {
        _ = setupOnce
    }
}
