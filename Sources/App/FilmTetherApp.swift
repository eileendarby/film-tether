import SwiftUI
import AppKit
import os

private let layoutLog = Logger(subsystem: "co.wonders.filmtether", category: "Layout")

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
                // No .frame minimum here at all. SwiftUI's own content-derived
                // window minimum proved unreliable — it reported 1280 while the
                // toolbar needed more, so the window could still be dragged
                // narrow enough to clip controls. MainView measures the
                // icons-only toolbar at runtime and pins NSWindow.contentMinSize
                // to it instead (see WindowSizing.swift), which is both
                // authoritative and self-maintaining as buttons are added.
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
        // .contentMinSize deliberately NOT used: it re-derives a minimum from
        // SwiftUI's own (wrong) idea of the content size on every layout pass
        // and clobbers the measured one set in WindowSizing.swift. .automatic
        // leaves NSWindow.contentMinSize alone so our measurement sticks.
        .windowResizability(.automatic)
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
                Divider()
                Button(model.previewAdjustments.invert
                       ? "Show Preview as Negative" : "Show Preview as Positive") {
                    model.toggleInvert()
                }
                .keyboardShortcut("i", modifiers: [.command])
                .help("Invert the preview so a negative shows as the positive image. Cmd-I. Display only — the captured RAW is still the negative.")
                Button(model.previewAdjustments.monochrome
                       ? "Show Preview in Color" : "Show Preview in Black & White") {
                    model.toggleMonochrome()
                }
                .keyboardShortcut("b", modifiers: [.command])
                .help("Raw pixels off a B&W negative carry no useful colour. Cmd-B. Display only — the saved files are untouched.")
                Button(model.isPickingWhiteBalance
                       ? "Cancel White Balance Pick" : "Pick White Balance from Preview…") {
                    model.toggleWhiteBalancePicker()
                }
                .disabled(!model.canPickWhiteBalance)
                .help("Then click the unexposed film base in the preview to neutralise its cast. Unavailable while the preview is inverted, where the base is the darkest part of the picture rather than the brightest.")
                Button("Clear Preview Tint Correction") {
                    model.resetWhiteBalance()
                }
                .disabled(model.previewAdjustments.whiteBalance == nil)
                .help("Drop the green/magenta correction the eyedropper applied to the preview. The camera's own colour temperature is left alone — change that from the toolbar.")
                Divider()
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

    /// Reports the window minimum the layout actually ended up enforcing.
    /// The toolbar's minimum width is derived from its compact layout rather
    /// than hardcoded, so this is the only way to see the real number — and it
    /// makes a regression (a control becoming reachable-but-clipped) visible
    /// instead of silent. Debug builds only via EOS_DEBUG; stream with:
    ///   log stream --predicate 'subsystem == "co.wonders.filmtether"' --info
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var report = ""
            for w in NSApp.windows where w.isVisible {
                // Passive report only. An earlier version force-resized the
                // window to prove the floor was enforced; that was useful once
                // but it shouldn't jostle a real window on every debug launch.
                let content = w.contentRect(forFrameRect: w.frame).size
                let line = """
                    contentMinSize=\(NSStringFromSize(w.contentMinSize)) \
                    content=\(Int(content.width))x\(Int(content.height))
                    """
                layoutLog.info("\(line, privacy: .public)")
                report += line + "\n"
            }
            // Also to a file: a GUI app has no useful stderr, and unified
            // logging isn't always readable from a sandboxed shell.
            let path = NSTemporaryDirectory() + "filmtether-layout.txt"
            try? report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

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
