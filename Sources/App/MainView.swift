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
                ScrollView(.horizontal, showsIndicators: false) {
                    ExposureBar()
                        .padding(.leading, 16)
                        .padding(.trailing, 24)    // breathing room so zoom button isn't flush against the window edge
                        .padding(.vertical, 10)
                }
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
