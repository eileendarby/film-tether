import Foundation
import ImageCaptureCore

/// Releases macOS's PTP claim on the Canon EOS 7D so libgphoto2 can take over.
///
/// macOS auto-launches `PTPCamera` helper + ImageCaptureCore via `ICDeviceBrowser` on hotplug.
/// Symptom if not released: `gp_camera_init` returns `GP_ERROR_IO_USB_CLAIM (-53)` or live view
/// stalls after 1-2 frames.
public final class ICDeviceClaim: NSObject, @unchecked Sendable, ICDeviceBrowserDelegate {
    /// Canon's USB vendor ID. Matches all Canon EOS bodies.
    private static let canonVendorID: Int = 0x04a9

    private let browser = ICDeviceBrowser()
    private var matchedDevices: [ICCameraDevice] = []
    private var completionHandlers: [() -> Void] = []

    override private init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
    }

    /// Release any macOS-side claim on a Canon EOS DSLR (any product). Returns after the
    /// browser has had a chance to enumerate (up to ~2s) and requestEject
    /// has been called on any matches.
    public static func releaseCanonEos() async {
        let claim = ICDeviceClaim()
        await claim.releaseInternal()
    }

    private func releaseInternal() async {
        browser.start()
        // Give the browser ~1.5s to enumerate; longer waits don't help on cold plug.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for device in matchedDevices {
            // requestEject() is the non-deprecated replacement for
            // requestEjectOrDisconnect() (deprecated macOS 10.15). The modern
            // overlay bridges it as async throws; best-effort, so try?/await.
            try? await device.requestEject()
        }
        // Allow eject to propagate.
        try? await Task.sleep(nanoseconds: 500_000_000)
        browser.stop()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser,
                              didAdd device: ICDevice,
                              moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        // Match any Canon body (vendor ID), or fall back to name match for legacy enumerations
        // that report vendor/product as 0.
        if camera.usbVendorID == Self.canonVendorID {
            matchedDevices.append(camera)
            return
        }
        let name = camera.name ?? ""
        if name.localizedCaseInsensitiveContains("Canon EOS") {
            matchedDevices.append(camera)
        }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser,
                              didRemove device: ICDevice,
                              moreGoing: Bool) {
        if let camera = device as? ICCameraDevice,
           let idx = matchedDevices.firstIndex(of: camera) {
            matchedDevices.remove(at: idx)
        }
    }

    /// Belt-and-suspenders fallback: terminate macOS's PTP camera helper processes.
    /// Safe to call even when no helper is running; absorbs all errors.
    ///
    /// Naming has changed across macOS versions:
    ///   - macOS 10.x-13: `PTPCamera`
    ///   - macOS 14+ (Sonoma/Sequoia/Tahoe): `/usr/libexec/ptpcamerad`
    /// We try every known name. Each `killall` is a no-op if the process isn't running.
    public static func killPTPCameraHelper() {
        let candidates = ["ptpcamerad", "PTPCamera"]
        for name in candidates {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments = [name]
            task.standardError = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }
}

