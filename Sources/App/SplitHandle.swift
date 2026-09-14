import SwiftUI
import AppKit

/// The draggable divider between the camera column and the archive tray.
/// Dragging left widens the tray. Deliberately not HSplitView: that keeps
/// its own idea of the divider position and ignores a changed idealWidth
/// after the first layout, so a remembered or default width never took.
struct SplitHandle: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat

    /// Hairline plus grab area either side.
    static let thickness: CGFloat = 9

    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .frame(width: Self.thickness)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if startWidth == nil { startWidth = width }
                        let proposed = (startWidth ?? width) - value.translation.width
                        width = Swift.min(maxWidth, Swift.max(minWidth, proposed))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize the archive tray")
    }
}
