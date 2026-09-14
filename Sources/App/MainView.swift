import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    /// Natural width of the icons-only toolbar, measured at runtime from an
    /// offscreen copy. This is the narrowest the window may ever be: below it
    /// a control would be clipped. Measured rather than hardcoded so it stays
    /// right as buttons are added.
    @State private var compactBarWidth: CGFloat = 0

    /// The tray's width, in points. Starts from the remembered value and is
    /// written back as the handle is dragged. Owned here rather than read
    /// off the tray's layout: a width that is *measured* and stored gets
    /// clobbered by the first layout pass, which is why HSplitView with an
    /// idealWidth never took a new default.
    @State private var trayWidth: CGFloat = CGFloat(AppSettings.shared.archiveTrayWidth)

    /// Room for the live-view pane itself, on top of the chrome. Focus checking
    /// needs a reasonably large image to be worth anything.
    private static let minPaneHeight: CGFloat = 420

    var body: some View {
        // A split the operator can drag: the camera column takes what the
        // tray leaves. The tray is never wider than the window can afford
        // beside the toolbar, whatever width was remembered.
        GeometryReader { geo in
            let affordable = max(ArchiveTray.minWidth, geo.size.width - compactBarWidth - SplitHandle.thickness)
            let width = min(trayWidth, affordable)
            HStack(spacing: 0) {
                cameraColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showArchiveTray {
                    SplitHandle(width: $trayWidth, minWidth: ArchiveTray.minWidth,
                                maxWidth: min(ArchiveTray.maxWidth, affordable))
                    ArchiveTray(archive: model.archive)
                        .frame(width: width)
                }
            }
        }
        .onChange(of: trayWidth) { _, w in AppSettings.shared.archiveTrayWidth = Double(w) }
        .background(Color(NSColor.windowBackgroundColor))
        // Offscreen copy of the icons-only bar, purely to learn its natural
        // width. `.fixedSize` makes it report what it actually wants rather
        // than accepting whatever the window currently offers; `.hidden` keeps
        // it invisible, and as a background it can't affect the real layout.
        .background(alignment: .topLeading) {
            exposureBar(compact: true, stacked: true)
                .fixedSize()
                .background(WidthReporter { compactBarWidth = $0 })
                .hidden()
                .allowsHitTesting(false)
        }
        .background(
            WindowMinContentSize(
                // The tray is a fixed-width column beside the camera, so when
                // it is open the floor is the toolbar plus the tray.
                width: compactBarWidth + (model.showArchiveTray ? ArchiveTray.minWidth + SplitHandle.thickness : 0),
                height: Self.minPaneHeight + chromeHeightEstimate
            )
        )
    }

    /// Preview, toolbar and footer — everything that was the whole window
    /// before the tray.
    private var cameraColumn: some View {
        ZStack {
            VStack(spacing: 0) {
                // Deliberately the LOWEST layout priority, not the highest.
                // It used to hold .layoutPriority(1), which meant SwiftUI sized
                // it first and its maxHeight:.infinity swallowed the whole
                // window — the toolbar and footer were then handed whatever was
                // left, which at small heights was nothing, so they were cut off
                // the bottom. The chrome below has a fixed, modest height; the
                // pane should take what remains, which is what happens when the
                // chrome is served first.
                LiveViewPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(0)
                Divider()
                // ExposureBar wrapped in horizontal scroll so the row of pickers + buttons
                // never gets clipped when the window is narrow.
                // Full-width bar when it fits, icons-only when it doesn't.
                // ViewThatFits does the choosing, so the switch happens exactly
                // when the labels would start being clipped rather than at a
                // hand-guessed pixel threshold — an earlier attempt used a
                // constant and got it wrong in the worst direction, leaving
                // buttons cut off across a wide band of window sizes.
                //
                // This must NOT be wrapped in a horizontal ScrollView: a scroll
                // view offers its content unlimited width, so the full bar would
                // always "fit" and the compact variant would never be chosen.
                // Dropping the ScrollView is also what stops buttons being
                // scrolled out of sight, and it lets the compact bar's own width
                // become the window's minimum via .windowResizability
                // (.contentMinSize) — so the window can no longer be made narrow
                // enough to hide a control.
                //
                // Left-aligned via a trailing Spacer rather than
                // `.frame(maxWidth: .infinity)`. That modifier makes the view
                // horizontally *flexible*, which discards the minimum width it
                // would otherwise report — so the window could still be dragged
                // narrower than the bar and clip the controls. A Spacer with
                // minLength 0 fills the same space while leaving the bar's own
                // minimum intact to propagate up as the window minimum.
                HStack(spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        exposureBar(compact: false)
                        exposureBar(compact: true)
                        exposureBar(compact: true, stacked: true)
                    }
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)   // chrome is sized before the preview pane
                Divider()
                StatusFooter()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            overlayContent()
        }
    }

    /// Toolbar + footer + dividers. Only used for the window's minimum height,
    /// so a close estimate is enough — the layout itself measures for real.
    private var chromeHeightEstimate: CGFloat { 170 }   // two toolbar rows at the narrowest

    /// One layout variant of the toolbar. Padding lives inside so ViewThatFits
    /// measures the real footprint, not the bare content.
    private func exposureBar(compact: Bool, stacked: Bool = false) -> some View {
        ExposureBar(compact: compact, stacked: stacked)
            .padding(.leading, 16)
            .padding(.trailing, 24)   // last button isn't flush to the window edge
            .padding(.vertical, 10)
    }

    @ViewBuilder
    private func overlayContent() -> some View {
        switch model.ui {
        case .disconnected, .enumerating:
            EmptyStates.NoCamera()
                .background(.ultraThinMaterial)
        case .ready, .streaming:
            EmptyView()
        case .error(let msg, let hint):
            EmptyStates.ErrorState(message: msg, hint: hint)
                .background(.ultraThinMaterial)
        }
    }
}
