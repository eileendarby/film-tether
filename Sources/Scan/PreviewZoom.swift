import Foundation
import CoreGraphics

/// How the live preview is scaled on screen.
///
/// The three states are expressed as magnification **relative to viewing the
/// whole frame at 1:1**, which is what a scanning operator actually cares about:
///
///   • `.fit`    — the whole frame, scaled to the pane. The percentage varies
///                 with window size and rotation, so it's computed live rather
///                 than baked into the case.
///   • `.actual` — 100%, one frame pixel per point. Bigger than fit on a normal
///                 window, and the honest "no scaling applied" reference.
///   • `.fiveX`  — 500%, which is the camera's own sensor punch-in rather than
///                 an upscale of the preview JPEG, so it shows real detail. This
///                 is the focus-check view.
public enum PreviewZoom: String, CaseIterable, Codable, Sendable {
    case fit
    case actual
    case fiveX

    /// Cycle order for the toolbar button: Fit → 100% → 500% → Fit.
    public var next: PreviewZoom {
        switch self {
        case .fit:    return .actual
        case .actual: return .fiveX
        case .fiveX:  return .fit
        }
    }

    /// True for the mode that needs the camera's sensor punch-in engaged.
    /// The other two are host-side scaling of a full-frame preview.
    public var engagesCameraPunchIn: Bool { self == .fiveX }

    /// Fixed magnification, or nil for `.fit` whose scale depends on geometry.
    public var fixedPercent: Int? {
        switch self {
        case .fit:    return nil
        case .actual: return 100
        case .fiveX:  return 500
        }
    }

    /// Button/menu label. `.fit` folds in the live percentage when one is
    /// available — it isn't while live view is off and there's no frame to
    /// measure, in which case the bare word is shown.
    public func label(fitPercent: Int?) -> String {
        switch self {
        case .fit:
            guard let fitPercent else { return "Fit" }
            return "Fit (\(fitPercent)%)"
        case .actual: return "100%"
        case .fiveX:  return "500%"
        }
    }

    /// Percentage at which a frame of `frame` points fits inside `pane` points.
    ///
    /// `frame` is the frame **as displayed**, i.e. already rotated, so rotating
    /// the preview naturally recomputes this: a 3:2 frame in a landscape pane
    /// fits at a very different scale than the same frame turned on its side.
    ///
    /// Returns nil when either size is degenerate (no frame yet, or the pane
    /// hasn't been laid out), which callers render as a bare "Fit".
    public static func fitPercent(frame: CGSize, pane: CGSize) -> Int? {
        guard frame.width > 0, frame.height > 0,
              pane.width > 0, pane.height > 0 else { return nil }
        let scale = min(pane.width / frame.width, pane.height / frame.height)
        guard scale.isFinite, scale > 0 else { return nil }
        return Int((scale * 100).rounded())
    }
}
