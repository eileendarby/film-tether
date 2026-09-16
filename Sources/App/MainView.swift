import SwiftUI
import Scan

struct MainView: View {
    @EnvironmentObject var model: AppModel

    /// Natural width of the icons-only toolbar, measured at runtime from an
    /// offscreen copy. This is the narrowest the window may ever be: below it
    /// a control would be clipped. Measured rather than hardcoded so it stays
    /// right as buttons are added.
    /// What the toolbar's pieces measure — the fixed part, each toggle
    /// labelled, each as an icon — from hidden copies laid out once, not per
    /// frame. The layout for any width is then arithmetic (ToolbarLayout),
    /// and one bar is rendered. Asking ViewThatFits to measure two dozen
    /// whole bars every layout pass made resizing crawl.
    @State private var pieceWidths = ToolbarLayout.Widths(
        fixed: 0,
        items: ExposureBar.compactable.map { ToolbarLayout.Item(labelled: 0, compact: $0 ? 0 : nil) },
        spacing: 10
    )
    /// The room the bar's row has, including the bar's own side paddings.
    @State private var barRoom: CGFloat = 0

    /// The bar's side paddings, applied in `exposureBar`.
    private static let barPadding: CGFloat = 16 + 24

    /// The narrowest the bar can be: every toggle an icon on the second
    /// row. This is the window's minimum width.
    private var compactBarWidth: CGFloat {
        guard pieceWidths.fixed > 0 else { return 0 }
        return ToolbarLayout.narrowest(items: ExposureBar.itemCount, compactable: ExposureBar.toggleCount)
            .width(pieceWidths) + Self.barPadding
    }

    private var chosenLayout: ToolbarLayout {
        guard pieceWidths.fixed > 0, barRoom > 0 else { return .row(labelled: ExposureBar.toggleCount) }
        return ToolbarLayout.choose(available: barRoom - Self.barPadding, widths: pieceWidths)
    }

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
        // Offscreen copies of the bar's pieces, purely to learn their natural
        // widths. `.fixedSize` makes each report what it actually wants rather
        // than accepting whatever the window offers; `.hidden` keeps them
        // invisible, and as a background they can't affect the real layout.
        .background(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ExposureBar(measuring: .fixed)
                    .fixedSize()
                    .background(WidthReporter { w in if pieceWidths.fixed != w { pieceWidths.fixed = w } })
                ForEach(0..<ExposureBar.itemCount, id: \.self) { i in
                    ExposureBar(measuring: .item(i, labelled: true))
                        .fixedSize()
                        .background(WidthReporter { w in if pieceWidths.items[i].labelled != w { pieceWidths.items[i].labelled = w } })
                    if ExposureBar.compactable[i] {
                        ExposureBar(measuring: .item(i, labelled: false))
                            .fixedSize()
                            .background(WidthReporter { w in if pieceWidths.items[i].compact != w { pieceWidths.items[i].compact = w } })
                    }
                }
            }
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
                // ToolbarLayout does the choosing, so the switch happens exactly
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
                    // The one layout for this width — see ToolbarLayout for
                    // the sequence — chosen from the measured pieces.
                    exposureBar(chosenLayout)
                    Spacer(minLength: 0)
                }
                .background(WidthReporter { w in if barRoom != w { barRoom = w } })
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

    /// One layout variant of the toolbar. Padding lives inside so the measured
    /// measures the real footprint, not the bare content.
    private func exposureBar(_ layout: ToolbarLayout) -> some View {
        ExposureBar(layout: layout)
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
