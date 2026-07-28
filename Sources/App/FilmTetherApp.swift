import SwiftUI
import AppKit

@main
struct FilmTetherApp: App {
    @StateObject private var model: AppModel = {
        _ = AppLaunch.bootstrap
        return AppModel()
    }()

    // NSApplicationDelegateAdaptor is the Apple-blessed way to hook the AppKit
    // lifecycle from SwiftUI. Adding the observer in App.init() instead caused
    // a known @StateObject double-instantiation issue (init-time access of
    // self.model creates AppModel A; view-mount creates AppModel B; views
    // observed B but our willTerminate handler held A, snapshot updates
    // published to B never reached the closure on A, and worse the @StateObject
    // identity got confused so .environmentObject's view tree didn't observe
    // the model that actually ran refreshSnapshot).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Film Tether") {
            MainView()
                .environmentObject(model)
                // 1400×820: comfortably wider than the full toolbar
                // contents (ISO/Tv/Av/WB/Format pickers + 6 focus buttons
                // + Capture + Stop LV + Peaking + Zoom buttons ≈ 1350px)
                // so the toolbar never has to scroll, AND tall enough
                // that the 3:2 LV image area gets ~600+ vertical pixels
                // for usable focus checking.
                .frame(minWidth: 1400, minHeight: 820)
                .task {
                    // Hand the model to the delegate so its applicationWillTerminate
                    // hook can run a clean stop() before the process dies.
                    AppDelegate.activeModel = model
                    // Window title stays the clean "Film Tether" (set by WindowGroup).
                    // The build identity now lives in About (App menu → About Film
                    // Tether) instead of the title bar, shipped builds shouldn't wear
                    // a dev stamp. Confirm a build via About or `defaults`/PlistBuddy
                    // on Info.plist BuildStamp.
                    await model.start()
                }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            // App menu → About Film Tether: shows version + the build stamp that
            // used to live in the title bar.
            CommandGroup(replacing: .appInfo) {
                Button("About Film Tether") { FilmTetherApp.showAboutPanel() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Capture") { Task { await model.captureNow() } }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button(model.isLiveViewOn ? "Stop Live View" : "Start Live View") {
                    Task {
                        if model.isLiveViewOn {
                            await model.stopLiveView()
                        } else {
                            await model.startLiveView()
                        }
                    }
                }
                .keyboardShortcut("l", modifiers: [.command])
                Divider()
                Button("Sync Camera Clock to Host") {
                    Task { await model.syncCameraClockLocal() }
                }
                .help("Push the host's LOCAL wall time to the camera so saved RAW EXIF DateTimeOriginal matches what you see in Finder")
                Button(model.showMeteringOverlay ? "Hide Zoom-Area Overlay" : "Show Zoom-Area Overlay") {
                    model.showMeteringOverlay.toggle()
                }
                .help("Toggle the rectangle showing where Shift-zoom will punch into. (Cmd-H removed because it conflicts with macOS's Hide Window.)")
                Button("Rotate Preview Right (now \(model.previewRotation.displayName))") {
                    model.rotatePreviewRight()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .help("Turn the live preview 90° clockwise. Cmd-R. Display only, and remembered across launches — the camera and the saved files are never rotated.")
                Button("Rotate Preview Left") {
                    model.rotatePreviewLeft()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .help("Turn the live preview 90° counter-clockwise. Cmd-Shift-R.")
                Button(model.focusPeakingEnabled ? "Disable Focus Peaking" : "Enable Focus Peaking") {
                    model.focusPeakingEnabled.toggle()
                }
                .keyboardShortcut("p", modifiers: [.command])
                .help("Overlay highlights on in-focus edges (host-side CoreImage filter). Cmd-P.")
                Button("Cycle Peaking Color (currently \(model.focusPeakingColor.rawValue))") {
                    model.cycleFocusPeakingColor()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .help("Cycle through cyan / magenta / yellow / white / lime. Cmd-Shift-P. Useful if the current color blends into the scene.")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    /// Standard macOS About panel, populated with the marketing version
    /// (Info.plist CFBundleShortVersionString) and the injected build stamp
    /// (git short hash + bundle time). This is where the build identity lives
    /// now that the title bar is clean for shipped builds.
    static func showAboutPanel() {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        let credits = NSAttributedString(
            string: "Built on libgphoto2 (LGPL 2.1 or later), part of the gPhoto project, "
                  + "along with the libraries it bundles (libusb, libexif, jpeg-turbo, and gd). "
                  + "Thanks to their maintainers.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Film Tether",
            .applicationVersion: version,
            .version: AppInfo.buildStamp,
            .credits: credits,
        ])
    }
}

/// AppKit delegate so we can hook the standard `applicationWillTerminate` path
/// for clean libgphoto2 shutdown. Without this the process gets SIGKILL'd by
/// Cmd-Q, libgphoto2 never calls gp_camera_exit, and the body's PTP session
/// stays wedged for the next launch (this produces -10 timeout chains until
/// the body is power-cycled the hard way).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from FilmTetherApp.body.task once SwiftUI has finished mounting the
    /// @StateObject AppModel. Reading it before that point is a programming
    /// error (and a no-op via the optional unwrap below).
    static var activeModel: AppModel?

    /// Async-clean shutdown. We CANNOT use applicationWillTerminate +
    /// DispatchGroup.wait: that blocks the main thread, but model.stop() is
    /// @MainActor and needs that exact thread, a self-deadlock that left the
    /// camera in live view (mirror up → wedged) and made quit hang the full
    /// timeout. applicationShouldTerminate + .terminateLater lets the run loop
    /// keep turning while stop() actually runs (dropping EVF + gp_camera_exit),
    /// then we reply to let the app die. A safety timer force-quits if stop()
    /// ever hangs on a sluggish body.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = AppDelegate.activeModel else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            NSApp.reply(toApplicationShouldTerminate: true)   // idempotent safety net
        }
        return .terminateLater
    }
}
