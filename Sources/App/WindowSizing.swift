import SwiftUI
import AppKit

/// Reports the laid-out width of whatever it's attached to as a background.
struct WidthReporter: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width, initial: true) { _, w in
                    onChange(w)
                }
        }
    }
}

/// Holds the host window to a measured minimum content size.
///
/// **Why this isn't just `.windowResizability(.contentMinSize)`:** SwiftUI's
/// content-derived minimum was measurably wrong here. It reported 1280pt while
/// the icons-only toolbar actually needs 1514pt, so the window could be dragged
/// 234pt narrower than its own controls and clip them off the right-hand edge.
/// SwiftUI also re-applies that wrong value on later layout passes, overwriting
/// anything set once at startup.
///
/// So this does two things: it sets `contentMinSize` (which handles the normal
/// case and the resize cursor), and it watches for resizes and pushes the window
/// back out if it ever lands under the floor. The second part is what makes the
/// guarantee hold even when something else overwrites the first.
///
/// The floor is measured at runtime from the real toolbar rather than
/// hardcoded, so it stays correct as buttons are added instead of silently
/// going stale — which is how the 1280 got in.
struct WindowMinContentSize: NSViewRepresentable {
    var width: CGFloat
    var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        v.isHidden = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.target = NSSize(width: width, height: height)
        // The window doesn't exist during the first layout pass, so defer.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            context.coordinator.attach(to: window)
        }
    }

    final class Coordinator {
        var target: NSSize = .zero
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        func attach(to window: NSWindow) {
            guard target.width > 0, target.height > 0 else { return }
            if self.window !== window {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                self.window = window
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.enforce()
                }
            }
            enforce()
            // SwiftUI overwrites contentMinSize on layout passes that land
            // after ours, so one apply at startup doesn't stick. Re-assert once
            // the layout has settled; without this the *first* drag starts from
            // SwiftUI's too-small floor and the window visibly snaps back
            // instead of simply refusing to go narrower.
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.enforce()
                }
            }
        }

        /// Re-assert the floor and, if the window is already under it, grow it
        /// back. Cheap enough to run on every resize notification: it exits
        /// immediately once the window is at or above the minimum.
        private func enforce() {
            guard let window, target.width > 0, target.height > 0 else { return }
            if window.contentMinSize != target {
                window.contentMinSize = target
                if ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1" {
                    let line = "applied contentMinSize=\(Int(target.width))x\(Int(target.height))\n"
                    try? line.write(
                        toFile: NSTemporaryDirectory() + "filmtether-minsize.txt",
                        atomically: true, encoding: .utf8
                    )
                }
            }
            let frame = window.frame
            let content = window.contentRect(forFrameRect: frame).size
            guard content.width < target.width - 0.5
                    || content.height < target.height - 0.5 else { return }
            let grown = NSSize(
                width: max(content.width, target.width),
                height: max(content.height, target.height)
            )
            var newFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: grown))
            // Keep the title bar put rather than growing downward off-screen.
            newFrame.origin = NSPoint(x: frame.origin.x, y: frame.maxY - newFrame.height)
            window.setFrame(newFrame, display: true, animate: false)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
