import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                LiveViewPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)   // LiveView eats all remaining space
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
                ViewThatFits(in: .horizontal) {
                    exposureBar(compact: false)
                    exposureBar(compact: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                StatusFooter()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            overlayContent()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

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
