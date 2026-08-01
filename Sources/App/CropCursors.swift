import AppKit
import Scan

/// Cursors for the crop box.
///
/// AppKit ships no public diagonal-resize cursor and no rotate cursor at all —
/// the ones Finder and Preview use are private (`_windowResizeNorthWestSouthEast`
/// and friends). Rather than reach for those, these are drawn from SF Symbols,
/// which gives the same shapes, scales on a Retina display, and can't break on
/// an OS update the way an undocumented selector can.
///
/// Each is drawn white with a dark outline underneath, because the pointer sits
/// over a live negative that may be almost any brightness — a plain black or
/// plain white cursor disappears into half of them.
enum CropCursors {

    static let resizeNorthWestSouthEast = make("arrow.up.left.and.arrow.down.right")
    static let resizeNorthEastSouthWest = make("arrow.up.right.and.arrow.down.left")
    static let resizeLeftRight = NSCursor.resizeLeftRight
    static let resizeUpDown = NSCursor.resizeUpDown
    static let rotate = make("arrow.trianglehead.counterclockwise.rotate.90",
                             fallback: "arrow.triangle.2.circlepath")

    /// The cursor for a zone, or nil to leave the pointer alone.
    static func cursor(for zone: CropBox.Zone) -> NSCursor? {
        switch zone {
        case .resize(let handle):
            switch handle {
            case .topLeft, .bottomRight: return resizeNorthWestSouthEast
            case .topRight, .bottomLeft: return resizeNorthEastSouthWest
            case .left, .right: return resizeLeftRight
            case .top, .bottom: return resizeUpDown
            case .interior: return nil
            }
        case .rotate: return rotate
        case .move: return NSCursor.openHand
        case .none: return nil
        }
    }

    // MARK: - Drawing

    private static let size: CGFloat = 20

    private static func make(_ symbol: String, fallback: String? = nil) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        guard let base, let glyph = base.withSymbolConfiguration(config) else {
            return NSCursor.arrow
        }
        let canvas = NSImage(size: NSSize(width: size, height: size))
        canvas.lockFocus()
        let rect = NSRect(
            x: (size - glyph.size.width) / 2, y: (size - glyph.size.height) / 2,
            width: glyph.size.width, height: glyph.size.height)
        // Outline first: the same glyph drawn black at a few offsets, so the
        // white one on top reads against a bright negative as well as a dark one.
        for dx in [-1.0, 0.0, 1.0] as [CGFloat] {
            for dy in [-1.0, 0.0, 1.0] as [CGFloat] where dx != 0 || dy != 0 {
                tint(glyph, .black).draw(in: rect.offsetBy(dx: dx, dy: dy))
            }
        }
        tint(glyph, .white).draw(in: rect)
        canvas.unlockFocus()
        return NSCursor(image: canvas, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }

    private static func tint(_ image: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect)
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }
}
