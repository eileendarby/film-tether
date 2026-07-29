import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    /// Natural width of the icons-only toolbar, measured at runtime from an
    /// offscreen copy. This is the narrowest the window may ever be: below it
    /// a control would be clipped. Measured rather than hardcoded so it stays
    /// right as buttons are added.
    @State private var compactBarWidth: CGFloat = 0

    /// Room for the live-view pane itself, on top of the chrome. Focus checking
    /// needs a reasonably large image to be worth anything.
    private static let minPaneHeight: CGFloat = 420

    var body: some View {
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
        .background(Color(NSColor.windowBackgroundColor))
        // Offscreen copy of the icons-only bar, purely to learn its natural
        // width. `.fixedSize` makes it report what it actually wants rather
        // than accepting whatever the window currently offers; `.hidden` keeps
        // it invisible, and as a background it can't affect the real layout.
        .background(alignment: .topLeading) {
            exposureBar(compact: true)
                .fixedSize()
                .background(WidthReporter { compactBarWidth = $0 })
                .hidden()
                .allowsHitTesting(false)
        }
        .background(
            WindowMinContentSize(
                width: compactBarWidth,
                height: Self.minPaneHeight + chromeHeightEstimate
            )
        )
    }

    /// Toolbar + footer + dividers. Only used for the window's minimum height,
    /// so a close estimate is enough — the layout itself measures for real.
    private var chromeHeightEstimate: CGFloat { 130 }

    /// One layout variant of the toolbar. Padding lives inside so ViewThatFits
    /// measures the real footprint, not the bare content.
    private func exposureBar(compact: Bool) -> some View {
        ExposureBar(compact: compact)
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
