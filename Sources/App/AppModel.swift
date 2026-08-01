import Foundation
import SwiftUI
import AppKit
import os
import Camera
import Hotkey
import Scan
import ImageIO

private let appLog = Logger(subsystem: "co.wonders.filmtether", category: "AppModel")
private let hotkeyLog = Logger(subsystem: "co.wonders.filmtether", category: "Hotkey")

/// Build identity, injected into Info.plist by scripts/bundle.sh (git short hash
/// + build time). Surfaced in the window title so we can always confirm exactly
/// which build is running.
enum AppInfo {
    static var buildStamp: String {
        (Bundle.main.infoDictionary?["BuildStamp"] as? String) ?? "dev"
    }

    /// Where the in-app "supported cameras" links point. The app UI stays
    /// camera-agnostic ("compatible camera"); the authoritative tested/supported
    /// list lives in the public repo. TODO(publish): set to the real public
    /// repo URL once the GitHub release repo is created.
    static let supportedCamerasURL = URL(string: "https://github.com/chriscantey/film-tether#supported-cameras")!
}

@MainActor
final class AppModel: ObservableObject {
    enum UIState: Equatable {
        case disconnected
        case enumerating
        case ready
        case streaming
        case error(message: String, hint: String?)
    }

    struct PropertySnapshot: Equatable {
        // Raw values straight from libgphoto2 (terse strings like "160", "2.8",
        // "0.005", "AV"). Kept around so picker writes round-trip exactly the
        // value libgphoto2 expects.
        var iso: String = "—"
        var shutter: String = "—"
        /// Last non-"Auto" shutter value observed during this session. In Av
        /// mode the body returns "Auto" most of the time and a numeric value
        /// briefly after a metering pass, this field captures that brief
        /// numeric value and persists it so the user always sees what the
        /// camera most-recently decided. Updated by AppModel.refreshSnapshot.
        var meteredShutter: String? = nil
        var aperture: String = "—"
        var whiteBalance: String = "—"
        var whiteBalanceKelvin: Int? = nil
        var mode: String = "—"
        var imageFormat: String = "—"
        var battery: String = "—"
        var meteringMode: String = "—"
        var cameraDateTime: Date? = nil
        /// Camera clock minus host clock at the last read. See
        /// `refreshSnapshot` for why the offset is stored rather than only the
        /// timestamp. Nil until the camera's clock has been read once.
        var cameraClockOffset: TimeInterval? = nil
        var fps: Double = 0

        // Pretty-formatted display strings. Computed from raw values via
        // PropertyLabels, UI shows these.
        var isoLabel: String { PropertyLabels.iso(iso) }
        var shutterLabel: String { PropertyLabels.shutter(shutter) }
        var apertureLabel: String { PropertyLabels.aperture(aperture) }
        var whiteBalanceLabel: String { PropertyLabels.whiteBalance(whiteBalance) }
        var kelvinLabel: String { PropertyLabels.kelvin(whiteBalanceKelvin) }
        var modeLabel: String { PropertyLabels.exposureMode(mode) }
        var imageFormatLabel: String { PropertyLabels.imageFormat(imageFormat) }
        var batteryLabel: String { PropertyLabels.battery(battery) }
    }

    @Published private(set) var ui: UIState = .disconnected
    @Published private(set) var snapshot = PropertySnapshot()
    @Published private(set) var latestFrame: NSImage? = nil
    @Published private(set) var lastCapture: String? = nil
    @Published private(set) var capturedFiles: [URL] = []
    @Published private(set) var zoomMode: LiveZoom.Mode = .fit
    @Published private(set) var zoomFallbackActive: Bool = false
    /// Relative focus index: client-side running total of commanded manual-focus
    /// step magnitudes (Near +, Far −) since the last reset. The camera reports
    /// no absolute focus position, so this is a directional tracker for
    /// repeatability, NOT physical distance. Reset via `resetFocusPosition()`.
    @Published private(set) var focusStepPosition: Int = 0
    @Published private(set) var isoChoices: [String] = []
    @Published private(set) var shutterChoices: [String] = []
    @Published private(set) var apertureChoices: [String] = []
    @Published private(set) var imageFormatChoices: [String] = []
    @Published private(set) var whiteBalanceChoices: [String] = []
    @Published private(set) var meteringModeChoices: [String] = []
    @Published private(set) var permissionsState: PermissionsState = .init()
    /// Diagnostic: incremented on every successful snapshot refresh. Used to
    /// verify @Published observation is wired correctly when UI fields appear
    /// stuck at defaults despite the backing values updating.
    @Published private(set) var snapshotTick: Int = 0
    /// Toggle for the metering / zoom box overlay in the LV pane. Default
    /// is now ON (like the Cmd-P toggle, it should just stay on) and persisted
    /// via AppSettings.
    var showMeteringOverlay: Bool {
        get { AppSettings.shared.showMeteringOverlay }
        set {
            AppSettings.shared.showMeteringOverlay = newValue
            objectWillChange.send()
        }
    }
    /// Normalized [0,1] x [0,1] center point of the metering / zoom rect.
    /// Default = dead center. Drag on the overlay updates this.
    @Published var meteringCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Focus peaking overlay toggle. Persisted via AppSettings so the
    /// last on/off state is remembered across launches.
    var focusPeakingEnabled: Bool {
        get { AppSettings.shared.focusPeakingEnabled }
        set {
            AppSettings.shared.focusPeakingEnabled = newValue
            objectWillChange.send()
        }
    }

    /// Color of the peaking overlay, proxied to AppSettings so the choice
    /// persists across launches and the Settings UI's swatch grid stays in
    /// sync with the Cmd-Shift-P cycle.
    var focusPeakingColor: FocusPeaking.PeakColor {
        get { AppSettings.shared.focusPeakingColor }
        set {
            AppSettings.shared.focusPeakingColor = newValue
            objectWillChange.send()
        }
    }

    /// Detection mode (edges vs grain). Same persistence story as color.
    var focusPeakingMode: FocusPeaking.Mode {
        get { AppSettings.shared.focusPeakingMode }
        set {
            AppSettings.shared.focusPeakingMode = newValue
            objectWillChange.send()
        }
    }

    /// Quarter-turn rotation of the live preview, proxied to AppSettings so it
    /// survives relaunches. Display-only: the camera is never told about it and
    /// captured files keep the body's native orientation. See `PreviewRotation`
    /// for why every other coordinate in this class stays in sensor space.
    var previewRotation: PreviewRotation {
        get { AppSettings.shared.previewRotation }
        set {
            AppSettings.shared.previewRotation = newValue
            objectWillChange.send()
        }
    }

    /// Aspect ratio the preview pane should letterbox to. The body streams 3:2
    /// at every zoom level, so only rotation can change this.
    var previewAspectRatio: CGFloat {
        previewRotation.displayAspect(sensorAspect: 3.0 / 2.0)
    }

    /// How the preview is scaled on screen. Session state, not persisted —
    /// Fit is the right thing to land on every time you sit down.
    @Published private(set) var previewZoom: PreviewZoom = .fit
    /// Size of the preview pane in points, reported by the view layer. Feeds the
    /// live "Fit (N%)" readout, so it has to come from real laid-out geometry
    /// rather than an assumption about window size.
    @Published var previewPaneSize: CGSize = .zero
    /// Base zoom to restore when a momentary Shift-hold punch-in ends. Without
    /// this, releasing Shift always dropped to Fit even if you were at 100%.
    private var zoomBeforeHold: PreviewZoom = .fit

    /// Centre of the on-screen window over the frame while zoomed, normalized
    /// in **displayed** (rotated) space — the same space the navigator is drawn
    /// in, so dragging there needs no conversion.
    @Published private(set) var previewPanCenter = CGPoint(x: 0.5, y: 0.5)

    /// Whole-frame overview for the navigator. Held from the most recent
    /// full-frame arrival, because at 500% the camera streams only the magnified
    /// region and there is no live full frame to draw an overview from.
    @Published private(set) var navigatorThumbnail: NSImage?

    /// Backing for `scheduleCameraPan`: the in-flight move, and whether the
    /// target has changed since it started.
    private var cameraPanTask: Task<Void, Never>?
    private var cameraPanDirty = false

    /// Size of the displayed frame in pixels, after rotation.
    private var displayedFrameSize: CGSize {
        navigatorThumbnail?.size ?? latestFrame?.size ?? .zero
    }

    /// Fraction of the frame on screen, and so whether panning is possible.
    var previewVisibleSize: CGSize {
        let r = previewVisibleRegion
        return CGSize(width: r.width, height: r.height)
    }

    /// True when the preview is showing less than the whole frame, i.e. the
    /// navigator is worth drawing.
    var isPreviewPannable: Bool {
        previewZoom != .fit && PreviewViewport.isPannable(visibleSize: previewVisibleSize)
    }

    /// Region of the whole frame currently on screen, normalized in displayed
    /// space. This is what the navigator's indicator draws.
    ///
    /// The two zoomed modes mean different things and are computed differently.
    /// At 100% the camera streams the whole frame and we show a window onto it,
    /// so the region is host-side geometry. At 500% the camera streams *only*
    /// the magnified region, so the region on screen is wherever the body's
    /// punch-in is pointed — which is `meteringCenter`, in sensor space, mapped
    /// through the rotation to match the navigator.
    var previewVisibleRegion: CGRect {
        switch previewZoom {
        case .fit:
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .actual:
            return PreviewViewport.visibleRect(
                frame: displayedFrameSize, pane: previewPaneSize,
                scale: 1, center: previewPanCenter
            )
        case .fiveX:
            let f = AppModel.zoomBoxFraction
            let c = previewRotation.displayPoint(fromSensor: meteringCenter)
            return CGRect(x: c.x - f / 2, y: c.y - f / 2, width: f, height: f)
        }
    }

    /// Move the on-screen window, from a normalized centre in displayed space.
    ///
    /// At 100% this is a host-side scroll. At 500% it has to move the camera's
    /// punch-in instead, since that's what determines which pixels arrive at
    /// all — so it routes through the existing `eoszoomposition` path rather
    /// than duplicating it.
    func setPreviewPanCenter(_ center: CGPoint) async {
        switch previewZoom {
        case .fit:
            return
        case .actual:
            previewPanCenter = PreviewViewport.clampCenter(
                center, visibleSize: previewVisibleSize
            )
        case .fiveX:
            let f = AppModel.zoomBoxFraction
            let lo = f / 2, hi = 1 - f / 2
            let sensor = previewRotation.sensorPoint(fromDisplay: center)
            meteringCenter = CGPoint(
                x: min(max(sensor.x, lo), hi),
                y: min(max(sensor.y, lo), hi)
            )
            await moveCameraZoomToMeteringCenter()
        }
    }

    /// Pan by a scroll over the preview, so reaching another part of the
    /// negative doesn't mean travelling to the navigator every time.
    ///
    /// `delta` is in points, in AppKit's scroll convention. Horizontal comes
    /// along for free and is worth having: at 100% a rotated frame is usually
    /// off-screen sideways too.
    func scrollPreview(by delta: CGSize) {
        guard isPreviewPannable else { return }
        let visible = previewVisibleSize
        let region = previewVisibleRegion
        let next = PreviewViewport.pannedCenter(
            CGPoint(x: region.midX, y: region.midY),
            byScroll: delta, visibleSize: visible, pane: previewPaneSize
        )
        switch previewZoom {
        case .fit:
            return
        case .actual:
            // Pure host-side crop offset: free, so every event can be honoured.
            previewPanCenter = next
        case .fiveX:
            // Moving the body's punch-in is a USB write costing tens of
            // milliseconds, and scroll events arrive far faster than that.
            // Update the centre now so the navigator tracks the gesture, and
            // let the camera catch up on its own schedule.
            let f = AppModel.zoomBoxFraction
            let lo = f / 2, hi = 1 - f / 2
            let sensor = previewRotation.sensorPoint(fromDisplay: next)
            meteringCenter = CGPoint(
                x: min(max(sensor.x, lo), hi),
                y: min(max(sensor.y, lo), hi)
            )
            scheduleCameraPan()
        }
    }

    /// Coalesce a burst of scroll events into as few camera moves as possible.
    ///
    /// One move is in flight at a time; anything that arrives meanwhile just
    /// marks the target dirty, and the loop picks up whatever `meteringCenter`
    /// has become. The dirty flag is what keeps the *last* event from being
    /// dropped — without it, an event landing during a move would be swallowed
    /// and the body would settle somewhere the operator didn't ask for.
    private func scheduleCameraPan() {
        cameraPanDirty = true
        guard cameraPanTask == nil else { return }
        cameraPanTask = Task { [weak self] in
            defer { self?.cameraPanTask = nil }
            while self?.cameraPanDirty == true {
                self?.cameraPanDirty = false
                // Let the burst finish before spending a write on it.
                try? await Task.sleep(nanoseconds: 120_000_000)
                await self?.moveCameraZoomToMeteringCenter()
            }
        }
    }

    /// Point the body's punch-in at the current metering centre. Extracted so
    /// the arrow-key nudge and the navigator drag drive the same code.
    private func moveCameraZoomToMeteringCenter() async {
        guard zoomMode != .fit, !zoomFallbackActive, let lz = liveZoom else { return }
        let (x, y) = bodyZoomTopLeft()
        self.zoomBodyCenter = (x, y)
        await withLVPriority { try? await lz.setZoomPosition(x: x, y: y) }
    }

    // MARK: - Straightening

    /// Rotation beyond the quarter turn, in degrees clockwise.
    ///
    /// This is what the crop box's rotate handles drive. It turns the *picture*
    /// under a crop box that stays square to the screen, which is how
    /// straightening works everywhere else and the only arrangement in which the
    /// operator can see whether a film edge has been brought level.
    var previewFineRotation: Double {
        get { AppSettings.shared.previewFineRotation }
        set {
            AppSettings.shared.previewFineRotation = min(max(newValue, -45), 45)
            objectWillChange.send()
        }
    }

    /// The whole rotation applied to the preview, normalized to 0..<360.
    var totalRotationDegrees: Double {
        let raw = Double(previewRotation.rawValue) + previewFineRotation
        return raw.truncatingRemainder(dividingBy: 360) + (raw < 0 ? 360 : 0)
    }

    /// Label for the rotation button: whole degrees while unstraightened, one
    /// decimal once it isn't, because a tenth of a degree is a visible amount of
    /// straightening on a 5000-pixel negative.
    var rotationLabel: String {
        previewFineRotation == 0
            ? "\(previewRotation.rawValue)°"
            : String(format: "%.1f°", totalRotationDegrees)
    }

    func resetFineRotation() {
        guard previewFineRotation != 0 else { return }
        previewFineRotation = 0
        showNotice("Straightening cleared")
    }

    // MARK: - Crop

    /// The crop, in **display** space: normalized [0,1]², y-down, in the rotated
    /// orientation on screen.
    ///
    /// Display space because straightening turns the picture *under* a box that
    /// stays square to the screen. In sensor space that same box is a rotated
    /// quadrilateral, and the editor would have to carry the angle through every
    /// grip. Storing what's on screen keeps the editing arithmetic to
    /// rectangles; the corners in the scanned image are recovered by undoing the
    /// rotation, which is a single transform applied once.
    ///
    /// A quarter turn of the preview does move the box with the film — see
    /// `rotatePreviewRight`.
    @Published var cropRect: CGRect?

    /// Format the session expects, carried from one negative to the next.
    ///
    /// An operator works through a stack of one format, so the last confirmed
    /// one is a strong prior for the next — strong enough to reject a detection
    /// whose shape no such frame could have. Persisted, because a session
    /// usually resumes where it left off.
    var expectedFilmSize: FilmSize? {
        get { AppSettings.shared.expectedFilmSize }
        set {
            AppSettings.shared.expectedFilmSize = newValue
            objectWillChange.send()
        }
    }

    /// Pixel size of the most recent capture, so the crop can be reported in the
    /// coordinates of the file it will be applied to rather than the preview's.
    @Published private(set) var lastCaptureSize: CGSize?

    /// Size the crop's corners are quoted in: the captured file when one has
    /// arrived, the live frame until then.
    var cropReferenceSize: CGSize? {
        lastCaptureSize ?? latestFrame?.size
    }

    var isCropActive: Bool { cropRect != nil }

    /// True while the box is being adjusted: handles showing, everything outside
    /// darkened, and the overlay taking the pointer.
    ///
    /// Applying the crop drops out of this, because the overlay covers the whole
    /// pane and would otherwise sit between the operator and every other tool —
    /// the eyedropper and the metering box are both underneath it.
    @Published private(set) var isCropEditing = false

    /// The crop as applied, for whatever consumes it — the sidecar and the API,
    /// once those exist.
    struct AppliedCrop: Equatable {
        /// Corners in display space, normalized and y-down.
        var rect: CGRect
        /// Straightening in force when it was applied, degrees clockwise.
        var angle: Double
        /// Corners in the reference image's pixels, if its size is known.
        var pixels: CGRect?
        var size: FilmSize?
    }

    @Published private(set) var appliedCrop: AppliedCrop?

    /// Fix the crop and hand the interface back.
    func applyCrop() {
        guard let rect = cropRect else { return }
        isCropEditing = false
        appliedCrop = AppliedCrop(rect: rect, angle: totalRotationDegrees,
                                  pixels: cropPixelRect, size: expectedFilmSize)
        if let px = cropPixelRect {
            showNotice(String(format: "Crop applied — %.0f,%.0f → %.0f,%.0f",
                              px.minX, px.minY, px.maxX, px.maxY))
        } else {
            showNotice("Crop applied")
        }
        appLog.info("crop applied rect=\(String(describing: rect), privacy: .public) angle=\(self.totalRotationDegrees, privacy: .public)")
    }

    /// Go back to adjusting an applied crop.
    func editCrop() {
        guard cropRect != nil else { return }
        isCropEditing = true
    }

    /// Slack added to a detected crop, as a fraction of its own size.
    ///
    /// Detection stops on the boundary it found, so a crop taken exactly there
    /// can shave the outermost row of picture. On a 5300-pixel-wide 120 frame
    /// this works out at about 13 px overall, under 7 px a side — enough to stop
    /// the crop biting into the image, small enough that it doesn't visibly
    /// admit rebate.
    static let autoCropSlack = 0.0025

    /// Find the frame and put a crop box on it.
    ///
    /// Runs against the *unadjusted* frame — the JPEG exactly as the camera sent
    /// it. Inversion, monochrome and white-balance gains are all display
    /// corrections, and detection should see the film rather than the operator's
    /// view of it.
    func runAutoCrop() {
        guard let jpeg = lastUnadjustedFrame else {
            showNotice("No frame to crop — start live view first")
            return
        }
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            showNotice("Couldn't read the frame")
            return
        }
        // Detect on the frame as displayed, not as captured: the crop is stored
        // in display space, and rotating the *result* instead would turn an
        // upright rectangle into a tilted one that no longer is one.
        let turned = previewRotation.rotate(raw) ?? raw
        let cg = FineRotation.rotate(turned, byDegrees: previewFineRotation) ?? turned
        guard let plan = CropPlanner.plan(in: cg, expecting: expectedFilmSize) else {
            showNotice("No negative found — set the crop by hand, or check the framing")
            appLog.info("auto-crop: no plan")
            return
        }
        cropRect = CropBox.sanitised(
            CropBox.expanded(plan.rect, byFraction: Self.autoCropSlack))
        isCropEditing = true
        appliedCrop = nil

        // Learn from a detection we believed, so the next negative has a prior.
        // Only from `.detected`: the fallback's shape came *from* the
        // expectation, so treating it as evidence would be circular.
        if plan.route == .detected, let size = cropReferenceSize {
            let px = CGSize(width: plan.rect.width * size.width,
                            height: plan.rect.height * size.height)
            let match = FilmSizeMatcher.bestMatch(forCropSize: px, in: FilmSize.seedCatalog)
            if !match.isUnknown { expectedFilmSize = match }
        }

        let px = cropPixelRect
        showNotice(String(
            format: "Crop %@ — %.0f × %.0f%@",
            plan.route.rawValue, px?.width ?? 0, px?.height ?? 0,
            plan.anchoredEdge.map { " (anchored \($0.rawValue))" } ?? ""))
        appLog.info("auto-crop \(plan.route.rawValue, privacy: .public) rect=\(String(describing: plan.rect), privacy: .public) steps=\(plan.stableSteps, privacy: .public)")
    }

    func clearCrop() {
        cropRect = nil
        isCropEditing = false
        appliedCrop = nil
        showNotice("Crop cleared")
    }

    /// Pixel dimensions of an image file, from its metadata alone.
    ///
    /// `CGImageSourceCopyPropertiesAtIndex` reads the header, so this costs
    /// nothing next to a decode — which matters because it runs on every
    /// capture, on files that are 8000 pixels wide and RAW.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The crop in the reference image's pixels, for display.
    var cropPixelRect: CGRect? {
        guard let r = cropRect, let size = cropReferenceSize,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(x: r.minX * size.width, y: r.minY * size.height,
                      width: r.width * size.width, height: r.height * size.height)
    }

    // MARK: - Preview adjustments (monochrome + click white balance)

    /// Host-side preview corrections, proxied to AppSettings so they persist.
    /// Display-only: the camera keeps its own settings and captured files are
    /// never re-encoded. Recorded per scan so the same treatment can be
    /// replayed onto the RAW later.
    var previewAdjustments: PreviewAdjustments {
        get { AppSettings.shared.previewAdjustments }
        set {
            AppSettings.shared.previewAdjustments = newValue
            objectWillChange.send()
        }
    }

    /// True while the eyedropper is armed and the next click on the preview
    /// will sample white balance instead of moving the metering box.
    @Published private(set) var isPickingWhiteBalance: Bool = false

    /// Short-lived status line for the footer — used to explain a refused
    /// eyedropper sample, which otherwise just looks like a click that did
    /// nothing.
    @Published private(set) var notice: String? = nil
    private var noticeTask: Task<Void, Never>?

    /// Most recent frame as it came off the camera, before any adjustment.
    /// The eyedropper samples this rather than what's on screen: sampling the
    /// corrected preview would compound corrections, so clicking the same spot
    /// twice would drift instead of being a no-op.
    private var lastUnadjustedFrame: Data?

    /// Previous raw camera-clock reading, used to tell a live value from the
    /// driver's per-session cache. See `refreshSnapshot`.
    private var lastRawCameraClock: Date?

    func toggleMonochrome() {
        previewAdjustments.monochrome.toggle()
        appLog.info("preview monochrome → \(self.previewAdjustments.monochrome, privacy: .public)")
    }

    /// Flip the preview between the raw negative and the positive it will
    /// become. Display only — the captured RAW is still the negative.
    func toggleInvert() {
        previewAdjustments.invert.toggle()
        appLog.info("preview invert → \(self.previewAdjustments.invert, privacy: .public)")
        // White-balance picking is blocked while inverted (see
        // `canPickWhiteBalance`). Disarm on the way in, or the button would grey
        // out while the pane still sampled on the next click.
        if previewAdjustments.invert, isPickingWhiteBalance {
            isPickingWhiteBalance = false
            showNotice("White balance picking cancelled — switch to Negative to sample")
        }
    }

    /// White balance can only be sampled from the un-inverted negative.
    ///
    /// Sampling actually works fine while inverted — the eyedropper reads the
    /// original frame either way — but with the preview flipped, the film base
    /// is the *darkest* part of the picture rather than the brightest, so the
    /// operator is being asked to click the opposite of what they've learned to
    /// look for. Blocking it is a deliberate guard against picking the wrong
    /// spot, not a technical limitation.
    /// Also blocked at 100%, where the pane shows a window onto the frame rather
    /// than the whole of it: the click's position over the pane isn't its
    /// position in the frame, so the eyedropper would sample the wrong pixel.
    /// Fit and 5× both show a whole frame, so both are honest.
    var canPickWhiteBalance: Bool {
        isLiveViewOn && !previewAdjustments.invert && previewZoom != .actual
    }

    /// Arm or disarm the white-balance eyedropper.
    func toggleWhiteBalancePicker() {
        isPickingWhiteBalance.toggle()
        if isPickingWhiteBalance {
            showNotice("Click the film base to set white balance")
        }
    }

    /// Drop the host's tint correction. The camera's own temperature is left
    /// where it is — it's a camera setting, changed from the toolbar like any
    /// other, and silently rewinding it here would be a surprise.
    func resetWhiteBalance() {
        previewAdjustments.whiteBalance = nil
        isPickingWhiteBalance = false
        showNotice("Preview tint correction cleared — camera temperature unchanged")
        appLog.info("white balance tint reset")
    }

    /// Sample the frame at `point` (normalized, y-down, unrotated sensor space)
    /// and set the white balance that renders it neutral.
    ///
    /// The work is split between the camera and the host, because neither can do
    /// the whole job. The **body** takes the blue↔amber axis as a colour
    /// temperature — that's the half that matters, since it's the only half that
    /// reaches the RAW the scan actually keeps. The **host** takes the
    /// green↔magenta residue, which a Kelvin control cannot express at all and
    /// which a film base has plenty of. Splitting them this way also stops the
    /// two corrections from both attacking the blue/amber cast and overshooting.
    ///
    /// The temperature is an estimate against a measured model of this body (see
    /// `WhiteBalanceEstimate`), so it lands close rather than exactly. Clicking
    /// the same spot again re-measures from wherever the body now is and closes
    /// the remaining gap — repeated clicks converge.
    func sampleWhiteBalance(atSensor point: CGPoint) {
        isPickingWhiteBalance = false
        guard let jpeg = lastUnadjustedFrame else {
            showNotice("No frame to sample — start live view first")
            return
        }
        guard let s = PreviewPipeline.sampleColor(jpeg: jpeg, atNormalized: point) else {
            showNotice("Couldn't read that pixel")
            return
        }
        // Refusing beats applying a wild correction from a near-black sample,
        // but the user needs to know why nothing happened.
        guard ChannelGains.neutralizing(red: s.red, green: s.green, blue: s.blue) != nil else {
            showNotice("That spot is too dark to balance from — pick a brighter one")
            return
        }

        // The host's share: tint only. Applied immediately, since it costs
        // nothing and shows up on the very next frame.
        previewAdjustments.whiteBalance =
            WhiteBalanceEstimate.tintGains(red: s.red, green: s.green, blue: s.blue)

        // The camera's share: a colour temperature. Needs the body's current
        // setting, because the estimate is a correction to it — without a known
        // starting point there's nothing to correct *from*.
        guard let current = snapshot.whiteBalanceKelvin,
              let target = WhiteBalanceEstimate.kelvin(
                fromRed: s.red, green: s.green, blue: s.blue, currentKelvin: current)
        else {
            showNotice("Preview balanced — connect the camera to set its temperature too")
            appLog.info("white balance: host-only, no camera temperature to correct from")
            return
        }
        appLog.info("white balance sample r=\(s.red, privacy: .public) g=\(s.green, privacy: .public) b=\(s.blue, privacy: .public) → \(current, privacy: .public)K → \(target, privacy: .public)K")
        // Coming from any other mode, `current` is the temperature widget's
        // value rather than what the body was actually applying, so this first
        // estimate is only a starting point. Setting it also switches the body
        // into Color Temperature, which makes every later click exact.
        guard kelvinIsActive else {
            showNotice("White balance → \(target)K — click again to refine")
            Task { await setWhiteBalanceKelvin(target) }
            return
        }
        guard target != current else {
            showNotice("Already balanced at \(current)K")
            return
        }
        showNotice("White balance → \(target)K")
        Task { await setWhiteBalanceKelvin(target) }
    }

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Percentage at which the current frame fits the pane, or nil when there's
    /// nothing to measure (live view off, or pane not laid out yet).
    var previewFitPercent: Int? {
        guard let frame = latestFrame else { return nil }
        return PreviewZoom.fitPercent(frame: frame.size, pane: previewPaneSize)
    }

    /// Label for the zoom button, e.g. "Fit (85%)", "100%", "500%".
    var previewZoomLabel: String { previewZoom.label(fitPercent: previewFitPercent) }

    /// Advance the zoom button: Fit → 100% → 500% → Fit.
    func cyclePreviewZoom() async {
        await setPreviewZoom(previewZoom.next)
    }

    /// Set the display zoom and bring the camera's punch-in in line with it.
    /// Only 500% needs the body involved; Fit and 100% are host-side scaling of
    /// the same full-frame stream, so switching between those two costs no USB
    /// traffic at all.
    func setPreviewZoom(_ z: PreviewZoom) async {
        let wasPunchedIn = previewZoom.engagesCameraPunchIn
        self.previewZoom = z
        // Entering a zoom starts centred; leaving it makes the pan meaningless.
        self.previewPanCenter = CGPoint(x: 0.5, y: 0.5)
        appLog.info("preview zoom → \(z.rawValue, privacy: .public)")
        // Sampling is blocked at 100% (see `canPickWhiteBalance`). Disarm on the
        // way in, or the button greys out while the pane still samples on the
        // next click — the same trap as inverting with the picker armed.
        if !canPickWhiteBalance, isPickingWhiteBalance {
            isPickingWhiteBalance = false
            showNotice("White balance picking cancelled — sample at Fit or 500%")
        }
        guard z.engagesCameraPunchIn != wasPunchedIn else { return }
        await applyZoom(z.engagesCameraPunchIn ? .fivex : .fit)
    }

    func rotatePreviewRight() {
        // The box is stored in display space, so a quarter turn of the view
        // would otherwise leave it pointing at different film. Turning it the
        // same way keeps it on the negative it was put on.
        cropRect = cropRect.map { PreviewRotation.cw90.displayRect(fromSensor: $0) }
        // The button is for getting the negative the right way up, so it lands
        // on an exact quarter turn — straightening is a separate adjustment and
        // carrying it through would mean the button never reaches 0/90/180/270.
        previewFineRotation = 0
        previewRotation = previewRotation.rotatedRight
        appLog.info("preview rotation → \(self.previewRotation.rawValue, privacy: .public)°")
    }

    func rotatePreviewLeft() {
        cropRect = cropRect.map { PreviewRotation.cw270.displayRect(fromSensor: $0) }
        previewFineRotation = 0
        previewRotation = previewRotation.rotatedLeft
        appLog.info("preview rotation → \(self.previewRotation.rawValue, privacy: .public)°")
    }

    /// Cycle to the next peaking color. Wraps around after the last.
    func cycleFocusPeakingColor() {
        let all = FocusPeaking.PeakColor.allCases
        guard let idx = all.firstIndex(of: focusPeakingColor) else {
            focusPeakingColor = all.first ?? .cyan
            return
        }
        focusPeakingColor = all[(idx + 1) % all.count]
        appLog.info("focus peaking color → \(self.focusPeakingColor.rawValue, privacy: .public)")
    }
    var isLiveViewOn: Bool { ui == .streaming }

    struct PermissionsState: Equatable {
        var accessibility: Bool = false
        var inputMonitoring: Bool = false
    }

    // Held by AppModel after the connection is ready.
    private var connection: CameraConnection?
    private var session: CameraSession?
    private var properties: CameraProperties?
    private var capture: CameraCapture?
    private var liveView: LiveView?
    private var liveZoom: LiveZoom?
    private var hotkey: HoldKeyMonitor?
    private var connectionTask: Task<Void, Never>?
    private var liveViewTask: Task<Void, Never>?
    private var hotkeyTask: Task<Void, Never>?
    private var snapshotRefreshTask: Task<Void, Never>?
    /// Background drain of libgphoto2's event queue. Runs continuously while
    /// connected so we pick up property-change events the body emits during
    /// EVF (shutterspeed changes from the auto-meter, focusmode toggles,
    /// lensname on attach, etc). Without this loop the only way to learn
    /// the body's current state was to ask via gp_camera_get_config, which
    /// fights the EVF stream for the USB pipe. Event drain is push-based
    /// and free; the body is going to emit the events whether we drain
    /// them or not. Source: gphoto2 --wait-event probe on the 7D.
    private var eventDrainTask: Task<Void, Never>?
    /// Periodic meter-kick task. Fires Press Half / Release Half every ~2s
    /// during LV so the body emits a shutterspeed change event reflecting
    /// the CAPTURE-meter value (which on this body differs from the LV
    /// meter; the footer can read 1/100 while capture fires 1/150).
    /// Runs only while LV is streaming; cancelled before LV teardown so
    /// the body has a quiet pipe for viewfinder=0.
    private var meterKickTask: Task<Void, Never>?
    /// Holds CameraEvents on the actor side. Wrapped here so the event-drain
    /// task can reach it via a weak self.
    private var cameraEvents: CameraEvents?
    /// Zoom probe spawned by startLiveView. Must be cancelled in stopLiveView,
    /// otherwise its pending setZoom + fetchOnePreview calls will fire *after*
    /// the user's stop, re-opening the EVF (shutter re-opens audibly) and
    /// leaving the body in a state where the next Start is a no-op.
    private var zoomProbeTask: Task<Void, Never>?
    /// Cached zoom-probe result. Once we know whether camera-side zoom works
    /// for this session we don't re-run the probe on every LV start.
    private var zoomProbed: Bool = false
    private var fpsLastFrameAt: Date? = nil
    private var emaFps: Double = 0
    private var captureKeyMonitor: Any?
    /// Where the camera-side zoom box is currently centered, in body pixel
    /// coordinates. Updated by zoom-engage (synced from meteringCenter) and
    /// by each arrow nudge. Previously each nudge sent (center + step)
    /// regardless of where the body was zoomed, so arrows nudged left/right
    /// only once and then stopped moving. Stateful tracking fixes that.
    private var zoomBodyCenter: (x: Int, y: Int) = (2592, 1728)  // Evf-space center (5184×3456/2); recomputed on zoom
    /// Canon's `eoszoomposition` lives in the Evf (full-image) coordinate
    /// system, measured via an x-sweep on the 7D: x=0 → left edge,
    /// x≈2000 → middle, x≈4147 → right clamp. That's the 5184×3456 full-image
    /// space (NOT the 1056×704 LV JPEG; an earlier 1024×680 assumption is
    /// exactly why positioning never moved off the left edge). This is
    /// the same big coordinate system EOS Utility drives.
    /// Measured `eoszoomposition` mapping (template-match calibration,
    /// NCC 0.995 on two frames). The zoom rect's top-left in the
    /// 1056×704 OUTPUT relates to the eoszoomposition value by a straight line:
    ///   fit_px = origin + eoszoom × fitPxPerUnit
    /// Pinned exactly by x=0→fit-x 46 and x=3000→fit-x 617 (slope 0.1903,
    /// origin 46). We invert it to drive the zoom to where the box is. The
    /// +46/+50 origin (camera's zoom origin isn't the frame corner) was the
    /// systematic offset that made earlier mapping land short.
    /// Inverse of the camera's MEASURED zoom response (5-point corner+center
    /// dump). The 7D's eoszoom space maps to an INSET, COMPRESSED region of
    /// the displayed FOV (FOV/scale relationship, confirmed):
    /// eoszoom (0,0) lands the zoom CENTER at (0.133, 0.222), not the corner,     /// and eoszoom (4455,3120) lands it at (0.855, 0.842). So we invert that
    /// response: eoszoom = (box - offset) × gain, clamped to the camera range.
    /// Hardware limit: eoszoom can't go negative, so the zoom can't reach above
    /// ~0.12 (top) or left of ~0.04, a real 7D border, not a software bug.
    static let zoomRespOffset = CGPoint(x: 0.133, y: 0.222)
    static let zoomRespGain   = CGPoint(x: 6168, y: 5033)   // 1/measured-slope
    static let zoomEoszoomMax = CGPoint(x: 5000, y: 3800)   // camera clamps internally too
    /// The 5× zoom region as a fraction of the frame (measured 0.199). The box
    /// is drawn this size; the clamp + nudge use it too.
    static let zoomBoxFraction: CGFloat = 0.199
    private var observedLVFrameSize: (w: Int, h: Int)?

    // MARK: - Lifecycle

    func start() async {
        refreshPermissions()
        startCaptureKeyMonitor()
        let conn = await CameraConnection()
        self.connection = conn
        connectionTask = Task { [weak self] in
            await conn.startMonitoring()
            for await state in conn.stateStream {
                await self?.handleConnectionState(state)
            }
        }
    }

    func stop() async {
        connectionTask?.cancel()
        liveViewTask?.cancel()
        hotkeyTask?.cancel()
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        eventDrainTask?.cancel()
        eventDrainTask = nil
        meterKickTask?.cancel()
        meterKickTask = nil
        cameraEvents = nil
        hotkey?.stop()
        if let monitor = captureKeyMonitor {
            NSEvent.removeMonitor(monitor)
            captureKeyMonitor = nil
        }
        if let lv = liveView { try? await lv.stop() }   // cancels the LV loop (+ async EVF teardown)
        // Close the libgphoto2 session so the USB/PTP claim is released.
        // stopMonitoring() already calls session.close() (gp_camera_exit, which
        // also drops EVF), but we await it explicitly too for safety. The slow
        // explicit viewfinder/output writes that used to be here were REMOVED:
        // they were USB transactions that blew applicationWill-
        // Terminate's ~4s budget, so the close never ran, producing a long quit
        // with the camera left open. gp_camera_exit handles the EVF teardown.
        if let conn = connection { await conn.stopMonitoring() }
        await session?.close()
        connection = nil
        session = nil
        properties = nil
        capture = nil
        liveView = nil
        liveZoom = nil
    }

    // MARK: - Connection-state handling

    private func handleConnectionState(_ state: CameraConnection.ConnectionState) async {
        switch state {
        case .disconnected:
            self.session = nil
            self.properties = nil
            self.capture = nil
            self.liveView = nil
            self.liveZoom = nil
            self.ui = .disconnected
            self.latestFrame = nil
            // New session means a new cache, so the next reading is genuinely
            // fresh and must be allowed to set the offset.
            self.lastRawCameraClock = nil
            // Reset per-session state so the next connection re-probes zoom etc.
            self.zoomProbed = false
            zoomProbeTask?.cancel()
            zoomProbeTask = nil
            liveViewTask?.cancel()
            liveViewTask = nil
        case .enumerating:
            self.ui = .enumerating
        case .ready:
            guard let conn = connection else {
                self.ui = .error(message: "Connection ready but no connection object.", hint: nil)
                return
            }
            guard let sess = await conn.currentSession() else {
                self.ui = .error(message: "Connection ready but no session.", hint: nil)
                return
            }
            self.session = sess
            let props = await CameraProperties(session: sess)
            self.properties = props
            self.capture = await CameraCapture(session: sess, properties: props)
            let lv = await LiveView(session: sess, properties: props)
            self.liveView = lv
            self.liveZoom = await LiveZoom(session: sess)
            let evts = await CameraEvents(session: sess)
            self.cameraEvents = evts
            self.ui = .ready
            // Datetime sync was previously automatic on every connect. A body
            // went into the fatal "shooting is not possible, remove the
            // battery" error during an app restart with nothing else changing,
            // which is symptomatic of a libgphoto2 widget write that the 7D
            // firmware can't handle in some state. syncdatetimeutc was the
            // only write on the connect path, so it's the prime suspect. Now
            // user-triggered only, call model.syncCameraClock() from a menu.
            // Start the frame consumer ONCE per connection. AsyncStream isn't a
            // proper multicast subject, re-iterating it across stop/start cycles
            // (which the previous design did by recreating liveViewTask in
            // startLiveView) caused the second iterator to see an empty stream,
            // even when runLoop was clearly yielding frames per logs.
            // Long-lived consumer: runLoop's start()/stop() controls whether
            // frames flow; this loop just drains whatever arrives.
            liveViewTask?.cancel()
            liveViewTask = Task { [weak self] in
                for await frame in lv.frameStream {
                    await self?.handleFrame(frame)
                }
            }
            await refreshSnapshot()
            await loadChoices()
            startHotkey()
            startSnapshotRefresh()
            // NOTE: eventDrainTask is NOT started here. Starting it at
            // connect-ready meant the drain held the actor continuously
            // while idle, which kept the body's PTP daemon busy enough
            // that subsequent setViewfinder(0/1) writes failed to actually
            // move the mirror: the mirror failed to close or open on
            // Stop/Start. Drain only
            // matters during LV (metered Tv is an LV-only signal), so we
            // start it in startLiveView() and stop it in stopLiveView().
            // Opt-in auto-sync of the camera clock to host LOCAL wall time.
            // Default ON in AppSettings so the date is set automatically.
            // Local (not UTC)
            // is the fix for the EXIF DateTimeOriginal drift on bodies whose
            // internal TZ setting doesn't match the host (see
            // CameraProperties.syncDateTimeToHostLocal for the full story).
            if AppSettings.shared.autoSyncClockOnConnect {
                Task { [weak self] in await self?.syncCameraClockLocal() }
            }
        case .error(let msg):
            self.ui = .error(message: msg, hint: hintForMessage(msg))
        }
    }

    private func hintForMessage(_ msg: String) -> String? {
        let lower = msg.lowercased()
        if lower.contains("firmware") { return "Update your camera's firmware to the latest supported version (camera menu → wrench → Firmware Ver.)." }
        if lower.contains("usb") || lower.contains("claim") { return "Quit Image Capture and Photos, then unplug/replug the camera." }
        if lower.contains("timeout") || lower.contains("i/o") {
            return "Camera may be in a wedged state. Power the camera off, wait 3 seconds, power it on. The app will reconnect automatically."
        }
        if lower.contains("not detected") || lower.contains("no") { return "Set the camera's Communication menu to PTP." }
        return nil
    }

    // MARK: - Live view

    func startLiveView() async {
        appLog.info("startLiveView() called")
        guard let lv = liveView, let zoom = liveZoom else {
            appLog.error("startLiveView: liveView or liveZoom nil")
            return
        }
        // Reset overlay rect to dead center every LV session so it returns to
        // the center of the frame each time.
        self.meteringCenter = CGPoint(x: 0.5, y: 0.5)
        do {
            try await lv.start()
            self.ui = .streaming
            appLog.info("startLiveView: ui → .streaming")
            // Event drain is LV-coupled, only useful for picking up metered
            // Tv changes, which only happen during EVF. Start it after the
            // mirror is up; cancel in stopLiveView so the next mirror-down
            // write has a quiet PTP channel.
            startEventDrain()
            // startMeterKick() REMOVED, every-2s Press Half writes wedged
            // the body's firmware (needed power-cycle to recover). The 7D
            // can't tolerate sustained Press Half cycling even with C.Fn
            // IV-1 = AE lock. Tradeoff: footer's metered shutter no longer
            // updates in real-time; it only reflects what the LV-meter
            // emits (rare in Av/P modes) plus what arrives via the once-
            // per-capture Press Half. There may be NO safe way to get
            // real-time capture-meter parity on this body via libgphoto2.
            // NOTE: liveViewTask is started ONCE per connection in
            // handleConnectionState(.ready). Recreating it here would re-iterate
            // an already-consumed AsyncStream and silently see no frames.

            // 7D-only: we already know from prior probes that camera-side
            // eoszoom works (returns supported=true every time). Skipping the
            // probe entirely eliminates the visible "flash of zoom" on
            // LV start, the probe was running setZoom(.fivex) then back
            // to .fit which was visible in the preview pane. Hardcoded to
            // supported=true; zoomFallbackActive stays false.
            zoomProbed = true
            zoomFallbackActive = false
            _ = zoom  // silence unused warning while keeping the parameter shape
        } catch let err as CameraError {
            appLog.error("startLiveView CameraError: \(err.localizedDescription, privacy: .public)")
            self.ui = .error(message: err.localizedDescription, hint: nil)
        } catch {
            appLog.error("startLiveView error: \(String(describing: error), privacy: .public)")
            self.ui = .error(message: "\(error)", hint: nil)
        }
    }

    func stopLiveView() async {
        appLog.info("stopLiveView() called (ui=\(String(describing: self.ui), privacy: .public))")
        zoomProbeTask?.cancel()
        zoomProbeTask = nil
        // Stop the event drain AND the meter-kick BEFORE writing viewfinder=0,
        // so the body's PTP daemon has a quiet channel to actually drop the
        // mirror.
        eventDrainTask?.cancel()
        eventDrainTask = nil
        meterKickTask?.cancel()
        meterKickTask = nil
        if let lv = liveView {
            do { try await lv.stop(); appLog.info("LiveView.stop() OK") }
            catch { appLog.error("LiveView.stop() failed: \(String(describing: error), privacy: .public)") }
        }
        if case .streaming = ui { self.ui = .ready; appLog.info("stopLiveView: ui → .ready") }
        latestFrame = nil
        // Nothing left to sample, so an armed eyedropper would just fail on the
        // next click. The white balance itself is kept — it belongs to the film,
        // not to the live-view session.
        lastUnadjustedFrame = nil
        isPickingWhiteBalance = false
        // Reset zoom state so the next LV session starts at fit + center,
        // not whatever the last session left it at. Without this, the body's
        // zoom position persists across LV restarts (because we never
        // explicitly set it back to fit/center on stop) and the next Space-
        // hold zooms to the prior position instead of the current overlay
        // location.
        zoomMode = .fit
        previewZoom = .fit
        zoomBeforeHold = .fit
        previewPanCenter = CGPoint(x: 0.5, y: 0.5)
        navigatorThumbnail = nil
        zoomBodyCenter = (2592, 1728)  // Evf-space center; recomputed on next zoom anyway
    }

    private func handleFrame(_ frame: LiveView.Frame) async {
        // Gate on streaming state. The long-lived liveViewTask continues
        // draining lv.frameStream even after the user hits Stop, if runLoop
        // had a frame buffered when we cancelled, it'll arrive here and
        // overwrite latestFrame back to the old image. Dropping post-stop
        // frames keeps the preview pane truly empty when live view is off.
        guard ui == .streaming else { return }
        let now = Date()
        if let last = fpsLastFrameAt {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                let instantaneous = 1.0 / dt
                emaFps = emaFps == 0 ? instantaneous : (emaFps * 0.8 + instantaneous * 0.2)
                snapshot.fps = emaFps
            }
        }
        fpsLastFrameAt = now

        // Capture the FIT-frame dimensions so applyZoom positions eoszoom in
        // the right coordinate space. Only sample while at fit: the body
        // streams a different size when punched in (verified empirically:
        // fit=1056×704, zoom5×=1024×680), and eoszoomposition coordinates are
        // in the fit-frame space, sampling the zoomed size would skew the
        // reposition math during arrow-nudges.
        if zoomMode == .fit, let w = frame.width, let h = frame.height, w > 0, h > 0 {
            observedLVFrameSize = (w: w, h: h)
        }
        var jpeg = frame.jpegData
        // Client-side JPEG crop is now a FALLBACK only. When camera-side
        // sensor zoom is engaged (zoomFallbackActive == false), the body
        // already streams the sharp magnified frame, so we pass it straight
        // through, that's the whole point of the camera-side zoom path. We
        // only upscale-crop here if the body refused the eoszoom write.
        if zoomMode != .fit, zoomFallbackActive,
           let cropped = JPEGCrop.cropAt(jpeg, divisor: zoomMode.rawValue, center: meteringCenter) {
            jpeg = cropped
        }
        // Keep the frame exactly as the camera sent it for the eyedropper to
        // sample; everything below is correction the sample must not see.
        lastUnadjustedFrame = jpeg
        let peaking = focusPeakingEnabled
            ? PreviewPipeline.Peaking(
                mode: focusPeakingMode,
                intensity: Float(AppSettings.shared.focusPeakingIntensity),
                color: focusPeakingColor
              )
            : nil
        // One decode, one Core Image graph, one bitmap out. Returns nil when
        // there's nothing to apply, which is the common case — then the JPEG
        // goes straight to NSImage and Core Image never runs.
        let base = PreviewPipeline.render(
            jpeg: jpeg, adjustments: previewAdjustments, peaking: peaking
        ) ?? NSImage(data: jpeg)
        // Draw the zoom box DIRECTLY INTO the frame (image-pixel space), not as
        // a separate SwiftUI overlay. This makes the box physically part of the
        // displayed image, so it can never drift from the image content the way
        // a floating overlay with its own geometry could, and since the zoom
        // maps from this same image space, the box and the zoomed region are
        // the same thing by construction. Drawn only at fit + while hovering.
        var composed = base
        if let base, showMeteringOverlay, zoomMode == .fit {
            composed = Self.drawZoomBox(on: base, center: meteringCenter,
                                        fraction: AppModel.zoomBoxFraction)
        }
        // Rotation is deliberately the LAST step of composition: every overlay
        // above was positioned in sensor space, so turning the finished frame
        // keeps the box glued to the image content instead of sliding off it.
        let rotated = composed
            .map { previewRotation.rotate($0) }
            .map { FineRotation.rotate($0, byDegrees: previewFineRotation) }

        // Keep the newest *whole* frame for the navigator overview. Only frames
        // arriving while the body is at fit are whole — once punched in, the
        // camera sends just the magnified region, so there'd be nothing to draw
        // an overview from.
        if zoomMode == .fit, let rotated {
            self.navigatorThumbnail = rotated
        }

        // At 100% the pane fills the window rather than letterboxing, so the
        // frame is cropped to a window with the pane's shape. Cropping here (and
        // then scaling proportionally to fill) is what gives exact control over
        // which part is on screen — NSImageView's own scaling modes can only
        // centre or stretch, neither of which can pan.
        //
        // 500% is deliberately NOT cropped: the magnification has already
        // happened, either on the body or in the JPEG fallback above, and the
        // arriving frame *is* the visible region. Cropping it again to the same
        // region would magnify twice.
        if let rotated, previewZoom == .actual,
           let cropped = Self.crop(rotated, toNormalized: previewVisibleRegion) {
            self.latestFrame = cropped
        } else {
            self.latestFrame = rotated
        }
    }

    /// Crop an image to a normalized, y-down rect. Returns nil if the rect is
    /// degenerate or the image can't be decoded, so the caller falls back to
    /// showing the whole frame rather than nothing.
    private static func crop(_ image: NSImage, toNormalized rect: CGRect) -> NSImage? {
        guard rect.width > 0, rect.height > 0,
              rect.width < 0.999 || rect.height < 0.999,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // CGImage.cropping takes a top-left origin, matching our y-down rect.
        let px = CGRect(
            x: (rect.minX * w).rounded(), y: (rect.minY * h).rounded(),
            width: max(1, (rect.width * w).rounded()),
            height: max(1, (rect.height * h).rounded())
        ).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard px.width >= 1, px.height >= 1, let out = cg.cropping(to: px) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
    }

    /// Composite the zoom-target rectangle onto a copy of the frame in image
    /// pixel coordinates. `center` is normalized [0,1] top-down; NSImage's
    /// origin is bottom-left so we flip Y.
    private static func drawZoomBox(on image: NSImage, center: CGPoint, fraction f: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size))
        let bw = size.width * f, bh = size.height * f
        // Box is drawn at meteringCenter (already clamped to [f/2, 1-f/2] so it
        // reaches every edge and never goes off-screen). The constant offset
        // between box and where the camera zooms is applied in bodyZoomTopLeft
        // (zoom-side), so the box clamps cleanly here.
        let cx = center.x * size.width
        let cy = (1 - center.y) * size.height         // flip Y for AppKit coords
        let rect = CGRect(x: cx - bw/2, y: cy - bh/2, width: bw, height: bh)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = max(1.5, size.width / 480)  // ~2px at 1056-wide
        path.stroke()
        // small center crosshair
        let ch = NSBezierPath()
        ch.move(to: CGPoint(x: cx - 8, y: cy)); ch.line(to: CGPoint(x: cx + 8, y: cy))
        ch.move(to: CGPoint(x: cx, y: cy - 8)); ch.line(to: CGPoint(x: cx, y: cy + 8))
        ch.lineWidth = path.lineWidth; ch.stroke()
        out.unlockFocus()
        return out
    }

    // MARK: - Capture

    func captureNow() async {
        appLog.info("captureNow() called")
        guard let cap = capture else {
            appLog.error("captureNow: capture nil, connection not ready?")
            return
        }
        let folder = AppSettings.shared.captureFolder
        let pattern = AppSettings.shared.filenamePattern
        appLog.info("captureNow → \(folder.path, privacy: .public)/\(pattern, privacy: .public)")

        // The old gp_camera_capture path hung against EVF and so required a
        // pause/teardown/restart dance. The new eosremoterelease=Immediate
        // path inside CameraCapture honors the body's current LV+meter state
        //, capture happens with EVF UP, no mirror flap, no exposure shift.
        // That dance is gone. We DO still pause-via-priority through
        // withLVPriority so the capture's USB writes don't fight preview
        // frame fetches for the same wire.
        // Keep LV UP through capture. The previous EVF teardown forced the
        // body's REFLEX meter
        // (mirror down) to set capture exposure, which differed from the
        // LV preview (LV meter). EOS Utility doesn't drop the mirror; it
        // captures with LV up so the same sensor-based meter drives both
        // preview and captured exposure → they match.
        //
        // Historic concern: gp_camera_capture hung against viewfinder=1
        // on this body in earlier sessions. Re-testing fresh now that
        // C.Fn IV-1 is set. If it hangs/wedges, revert this block to
        // the lv.stop/lv.start dance.
        //
        // We DO still pause the LV frame fetch via withLVPriority (handled
        // inside cap.capture's caller, see kickMeter pattern) so the USB
        // pipe isn't fighting capture's writes.
        var captureResult: CameraCapture.CaptureResult?
        var captureError: Error?
        await withLVPriority {
            do {
                captureResult = try await cap.capture(to: folder, filenamePattern: pattern)
            } catch {
                captureError = error
            }
        }

        if let result = captureResult {
            self.lastCapture = result.path.lastPathComponent
            self.capturedFiles.append(contentsOf: result.allPaths)
            // Dimensions only — read from the file's metadata without decoding
            // it. The crop is defined on the preview but applied to this, so its
            // corners should be quoted in this file's pixels.
            self.lastCaptureSize = Self.pixelSize(of: result.path) ?? self.lastCaptureSize
            self.snapshot.iso = result.iso ?? self.snapshot.iso
            self.snapshot.shutter = result.shutter ?? self.snapshot.shutter
            self.snapshot.aperture = result.aperture ?? self.snapshot.aperture
            appLog.info("captureNow OK: \(result.path.lastPathComponent, privacy: .public)")
            // Pick up any side-effect property changes the camera made during
            // capture (focusmode auto-restored, AE state, etc).
            await refreshSnapshot()
        } else if let err = captureError as? CameraError {
            appLog.error("captureNow CameraError: \(err.localizedDescription, privacy: .public)")
            self.ui = .error(message: err.localizedDescription, hint: nil)
        } else if let err = captureError {
            appLog.error("captureNow error: \(String(describing: err), privacy: .public)")
            self.ui = .error(message: "\(err)", hint: nil)
        }
    }

    func triggerAutofocus() async {
        appLog.info("triggerAutofocus() called")
        guard let p = properties else { appLog.error("triggerAutofocus: properties nil"); return }
        // Wrap in LV-priority pause so the USB pipe is free for the AF
        // command. Without this the 30 FPS preview stream often hogs USB
        // and the body never sees a clean window for AF.
        await withLVPriority {
            do { try await p.triggerAutofocus() }
            catch let err as CameraError { appLog.error("triggerAutofocus: \(err.localizedDescription, privacy: .public)") }
            catch { appLog.error("triggerAutofocus: \(String(describing: error), privacy: .public)") }
        }
        await refreshSnapshot()
    }

    /// Push host *local* wall time → camera (TZ-aware). Used both by the auto-sync
    /// on connect and the explicit menu / footer click. Local-not-UTC because the
    /// 7D's EXIF DateTimeOriginal is a wall-clock value, UTC sync leaves a
    /// host_local - camera_local drift equal to the camera's TZ-vs-host-TZ
    /// offset (a 1-hour drift was observed with the camera set to PST while
    /// the host was in PDT). See CameraProperties for the
    /// detailed why.
    func syncCameraClockLocal() async {
        appLog.info("syncCameraClockLocal() called")
        guard let p = properties else {
            showNotice("Not connected — can't sync the clock")
            return
        }
        let tzOffset = AppSettings.shared.cameraTZOffsetMinutes
        // MUST run under withLVPriority, like every other camera write in this
        // class. Without it the write competes with the 30 FPS preview stream
        // for the USB pipe and fails with -110 (I/O in progress) during live
        // view — which is exactly when someone notices the clock and clicks it.
        // The throw was caught and only logged, so the click silently did
        // nothing and the readout never changed.
        var failure: Error?
        await withLVPriority {
            do {
                try await p.syncDateTimeToHostLocal(tzOffsetMinutes: tzOffset)
                appLog.info("camera datetime synced (tzOffset=\(tzOffset, privacy: .public)min)")
            } catch {
                failure = error
            }
        }
        if let failure {
            let message = (failure as? CameraError)?.localizedDescription
                ?? String(describing: failure)
            appLog.error("syncCameraClockLocal failed: \(message, privacy: .public)")
            // Surface it. A silent failure here is what made this look like a
            // dead button rather than a failed write.
            showNotice("Clock sync failed: \(message)")
            return
        }
        await refreshSnapshot()
        // A successful sync sets the camera's clock to the host's, so the offset
        // is zero by definition. Assert that rather than reading it back: the
        // driver caches this property per session, and there's no guarantee the
        // cache reflects a write we just made — trusting the read here is how
        // a freshly-synced clock could end up displaying a stale offset.
        var s = snapshot
        s.cameraClockOffset = 0
        snapshot = s
        lastRawCameraClock = s.cameraDateTime
        showNotice("Camera clock synced to host")
    }

    /// Legacy menu hook, still wired in FilmTetherApp's commands for users who
    /// explicitly want UTC sync. New code calls syncCameraClockLocal directly.
    func syncCameraClock() async {
        await syncCameraClockLocal()
    }

    /// Background event drain. While connected we keep one in-flight call
    /// against gp_camera_wait_for_event with a short timeout, when the body
    /// emits property events (Tv changes from the auto-meter, lensname on
    /// attach, etc) we pick them up and update snapshot. This is the
    /// foundation of real-time metered Tv display in Av mode where the
    /// shutterspeed widget reads "auto" but the actual value comes through
    /// the event stream.
    private func startEventDrain() {
        eventDrainTask?.cancel()
        eventDrainTask = Task { [weak self] in
            await self?.runEventDrain()
        }
    }

    private func runEventDrain() async {
        guard let evts = cameraEvents else { return }
        appLog.info("event drain: starting")
        while !Task.isCancelled {
            // Yield to user-priority ops. When `withLVPriority` pauses the
            // LV runLoop, the same signal pauses us, otherwise we'd be
            // calling gp_camera_wait_for_event in parallel with capture's
            // waitForFileAdded and one consumer would eat the other's
            // events, causing "capture failed: timeout waiting for file
            // added" on every second shot. 50ms re-check feels instant
            // when the user op finishes.
            if let lv = liveView, await lv.isPaused {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            // drain() swallows errors internally. Loop only exits on
            // Task.isCancelled.
            let events = await evts.drain(budgetMs: 200, perCallMs: 100)
            if events.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            for evt in events {
                await applyEvent(evt)
            }
        }
        appLog.info("event drain: exited")
    }

    /// Project one camera event onto the UI snapshot. Most events just
    /// mirror what the body is doing internally; the one that matters
    /// for user-visible state is shutterspeed changes during metering.
    private func applyEvent(_ evt: CameraEvents.Event) async {
        switch evt {
        case .propertyChanged(let name, let value, _):
            guard let name, let value else { return }
            switch name {
            case "shutterspeed":
                let isAutoish = value.lowercased() == "auto" || value.isEmpty
                var s = self.snapshot
                if !isAutoish { s.meteredShutter = value }
                // In a manual exposure mode the picker should follow the body.
                // In Av/Tv/P the picker shows "auto", the metered value goes
                // into meteredShutter only.
                if s.mode.uppercased().contains("MANUAL") || s.mode.uppercased() == "M" {
                    s.shutter = value
                } else if isAutoish {
                    s.shutter = value  // picker shows whatever the body says
                }
                self.snapshot = s
                self.snapshotTick &+= 1
            case "iso":
                var s = self.snapshot
                s.iso = value
                self.snapshot = s
            case "aperture":
                var s = self.snapshot
                s.aperture = value
                self.snapshot = s
            // focusmode events are useful but PropertySnapshot doesn't surface
            // focusMode in the UI today, capture path just writes Manual/
            // One Shot directly. Skip rather than carry dead state.
            default:
                break
            }
        case .fileAdded, .captureComplete, .timeout, .unknown:
            // Capture path drains its own FILE_ADDED inside CameraCapture;
            // anything that arrives here was emitted while we weren't
            // actively capturing, safe to ignore.
            break
        }
    }

    /// Drop-flag so rapid manual-focus button mashing doesn't queue dozens of
    /// USB writes. Mashing once fired ~40 writes in 11 seconds and
    /// blocked a subsequent ISO change with -110 IO_IN_PROGRESS. When one
    /// drive is already in flight, additional presses are ignored, the
    /// motor on the body has a physical settle time anyway.
    private var manualFocusInFlight: Bool = false

    /// Drive manual focus by one step in the requested direction. Lens must
    /// be in AF mode on the lens switch AND body focusmode set to a non-Manual
    /// value for the motor to actually move, most USM lenses comply when both
    /// are set right. Watch the live view to confirm the lens moved.
    func driveManualFocus(_ step: CameraProperties.ManualFocusStep) async {
        if manualFocusInFlight {
            appLog.debug("driveManualFocus(\(step.rawValue, privacy: .public)) dropped, prior write still in flight")
            return
        }
        manualFocusInFlight = true
        defer { manualFocusInFlight = false }
        appLog.info("driveManualFocus(\(step.rawValue, privacy: .public))")
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.driveManualFocus(step)
                // Only advance the relative index once the body accepted the
                // drive, a thrown write leaves the counter untouched.
                self.focusStepPosition += step.weight
            }
            catch let err as CameraError { appLog.error("driveManualFocus: \(err.localizedDescription, privacy: .public)") }
            catch { appLog.error("driveManualFocus: \(String(describing: error), privacy: .public)") }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    /// Reset the relative focus index to zero, the "you are here" origin the
    /// readout counts from. Does not move the lens.
    func resetFocusPosition() { focusStepPosition = 0 }

    /// Pause runLoop's frame fetching (via pauseCount), do the work, resume.
    /// Body state preserved, no mirror cycle, no focus loss. The AF cancel
    /// chaser in triggerAutofocus handles the body's AF-acquired state
    /// without needing a full LV teardown.
    ///
    /// If AF still wedges the body with just light pause + cancel, the AF
    /// button will be removed entirely (autofocus is optional).
    private func withLVPriority<T>(_ work: () async -> T) async -> T {
        guard let lv = liveView, isLiveViewOn else { return await work() }
        return await lv.withPriority { await work() }
    }

    func setMeteringMode(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setMeteringMode(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    /// Latched punch-in toggle, kept for any caller that wants a straight
    /// in/out flip rather than the three-state cycle on the toolbar button.
    func toggleZoom() async {
        await setPreviewZoom(previewZoom.engagesCameraPunchIn ? .fit : .fiveX)
    }

    func setImageFormat(_ value: String) async {
        appLog.info("setImageFormat(\(value, privacy: .public)) called")
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setImageFormat(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    // MARK: - Property setters

    func setISO(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setIso(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
        // kickMeter() removed from settings-change path, Press Half writes
        // (even occasional) correlate with body wedges that need power-cycle.
    }

    func setShutter(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setShutter(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    func setAperture(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setAperture(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    /// True when the body's white balance is the mode that actually uses the
    /// Kelvin value, so the stepper can be disabled rather than silently doing
    /// nothing the rest of the time.
    var kelvinIsActive: Bool {
        snapshot.whiteBalance.caseInsensitiveCompare(
            CameraProperties.colorTemperatureMode
        ) == .orderedSame
    }

    func setWhiteBalanceMode(_ value: String) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setWhiteBalance(value)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
        appLog.info("white balance mode → \(value, privacy: .public)")
    }

    func setWhiteBalanceKelvin(_ k: Int) async {
        guard let p = properties else { return }
        await withLVPriority {
            do {
                try await p.setWhiteBalanceKelvin(k)
                self.clearTransientErrorIfStreamingReady()
            }
            catch let err as CameraError { self.ui = .error(message: err.localizedDescription, hint: nil) }
            catch { self.ui = .error(message: "\(error)", hint: nil) }
        }
        await refreshSnapshot()
    }

    /// Start a periodic meter-kick task. Fires kickMeter() every ~2 seconds
    /// while LV is streaming so the footer's metered shutter updates even
    /// when the user is just sliding film (no settings changes to piggyback
    /// on). It re-meters every couple of seconds so sliding film alone still
    /// updates the meter.
    private func startMeterKick() {
        meterKickTask?.cancel()
        meterKickTask = Task { [weak self] in
            while !Task.isCancelled {
                // 2s cadence: fast enough that scene changes are visible
                // within ~2s; slow enough that the body isn't constantly
                // ticking AE locks. With C.Fn IV-1 = AE lock / AF, Press
                // Half is cheap, no AF noise, no mirror movement.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                await self?.kickMeter()
            }
        }
    }

    /// Fire one Press Half / Release Half cycle to nudge the body's auto-meter
    /// into emitting the "what would capture meter" shutterspeed value. With
    /// C.Fn IV-1 = "AE lock / AF" on the body, this is just a brief AE lock
    /// (no AF noise, no extra mirror activity). The shutterspeed change event
    /// gets caught by runEventDrain → updates snapshot.meteredShutter →
    /// footer shows the capture-meter value. Without this, the LV meter and
    /// capture meter diverge and the footer can read 1/100 while capture
    /// fires 1/150.
    ///
    /// Best-effort: skipped silently if LV is off (no point) or if the
    /// widget writes fail. Only runs while connected + streaming.
    private func kickMeter() async {
        guard isLiveViewOn, let p = properties else { return }
        await withLVPriority {
            try? await p.setString("eosremoterelease", value: "Press Half")
            try? await Task.sleep(nanoseconds: 120_000_000)
            try? await p.setString("eosremoterelease", value: "Release Half")
        }
    }

    /// If we're showing a transient property-write error but the camera is
    /// otherwise healthy (still autodetecting / responding), clear the error
    /// so a subsequent successful write doesn't leave a stale message in the
    /// UI. We only clear .error → .ready; never touch .streaming/.disconnected.
    private func clearTransientErrorIfStreamingReady() {
        if case .error = ui {
            ui = .ready
        }
    }

    private func refreshSnapshot() async {
        guard let p = properties else { appLog.error("refreshSnapshot: properties nil"); return }
        // Single gp_camera_get_config call covers every leaf we display, much
        // gentler on the body than 6+ independent get_config calls per refresh.
        // Wrap in LV priority so this read doesn't compete with preview frames
        // when LV is active.
        let snap: CameraProperties.Snapshot? = await withLVPriority {
            do { return try await p.snapshot() }
            catch {
                appLog.error("snapshot read failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let snap else { return }
        var s = self.snapshot
        if let v = snap.iso          { s.iso = v }
        if let v = snap.shutter {
            s.shutter = v
            let isAutoish = v.lowercased() == "auto" || v.isEmpty || v == "—"
            if !isAutoish {
                s.meteredShutter = v
            }
        }
        if let v = snap.aperture     { s.aperture = v }
        if let v = snap.whiteBalance { s.whiteBalance = v }
        s.whiteBalanceKelvin = snap.kelvin ?? s.whiteBalanceKelvin
        if let v = snap.mode         { s.mode = v }
        if let v = snap.imageFormat  { s.imageFormat = v }
        if let v = snap.battery      { s.battery = v }
        if let v = snap.meteringMode { s.meteringMode = v }
        if let camTime = snap.cameraDateTime {
            s.cameraDateTime = camTime
            // Store the camera-vs-host *offset* rather than the raw timestamp:
            // both clocks tick in real time, so the offset is the stable
            // quantity and the footer can reconstruct `now + offset`.
            //
            // Only recompute it from a reading we can prove is FRESH. The ptp2
            // driver caches this property for the life of the session — measured
            // with `clock-watch`: zero advance over 12s of wall time — so in the
            // app (one long-lived session, unlike the one-shot CLI) every read
            // after the first returns the connect-time value. Recomputing from
            // that made the offset a second more negative per second, so the
            // readout ticked forward and then snapped back by the full refresh
            // interval, over and over, while never matching the host.
            //
            // A changed reading proves the value is live; an identical one means
            // we're looking at the cache, and the existing offset is the better
            // estimate. The camera's clock itself is accurate (measured: ~1s
            // over 14 hours), so an offset taken once at connect stays good.
            let isFresh = camTime != lastRawCameraClock
            if isFresh {
                lastRawCameraClock = camTime
                s.cameraClockOffset = camTime.timeIntervalSince(Date())
            }
            if ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1" {
                // Appended so the *sequence* is visible: a healthy offset holds
                // steady, the old bug made it fall by one second per second.
                let line = String(
                    format: "%@ raw=%@ fresh=%@ offset=%+.0fs\n",
                    ISO8601DateFormatter().string(from: Date()),
                    ISO8601DateFormatter().string(from: camTime),
                    isFresh ? "Y" : "N",
                    s.cameraClockOffset ?? 0
                )
                let path = NSTemporaryDirectory() + "filmtether-clock.txt"
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                } else {
                    try? line.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        self.snapshot = s
        self.snapshotTick &+= 1
        appLog.info("snapshot[\(self.snapshotTick, privacy: .public)]: iso=\(s.iso, privacy: .public) Tv=\(s.shutter, privacy: .public) Av=\(s.aperture, privacy: .public) K=\(s.whiteBalanceKelvin ?? -1, privacy: .public) mode=\(s.mode, privacy: .public) fmt=\(s.imageFormat, privacy: .public) batt=\(s.battery, privacy: .public)")
    }

    private func loadChoices() async {
        guard let p = properties else { return }
        let cs: CameraProperties.ChoiceSet? = await withLVPriority {
            do { return try await p.choicesSnapshot() }
            catch {
                appLog.error("choices read failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        guard let cs else { return }
        self.isoChoices = cs.iso
        self.shutterChoices = cs.shutter
        self.apertureChoices = cs.aperture
        self.imageFormatChoices = cs.imageFormat
        self.whiteBalanceChoices = cs.whiteBalance
        self.meteringModeChoices = cs.meteringMode
        appLog.info("choices: iso=\(cs.iso.count, privacy: .public) shutter=\(cs.shutter.count, privacy: .public) aperture=\(cs.aperture.count, privacy: .public) imageFormat=\(cs.imageFormat.count, privacy: .public) meteringMode=\(cs.meteringMode.count, privacy: .public)")
    }

    /// Periodic background refresh, picks up settings the user changes on the camera
    /// body. Cadence intentionally slow to minimize PTP pressure on the body.
    /// Post-wedge: when LV is active we DON'T refresh (the LV stream itself shows
    /// what the body's doing; we don't need redundant property polls). When idle
    /// we tick every 10s. Was 1s/3s before the wedge incident that needed AC pull.
    private func startSnapshotRefresh() {
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let isStreaming = await MainActor.run { self.ui == .streaming }
                // Skip refresh entirely while LV is streaming, the body has
                // enough load just feeding 30 FPS preview. We rely on user
                // setting changes triggering their own refresh, and on the
                // post-action refreshSnapshot in captureNow / triggerAutofocus.
                // Idle cadence 10s (was 3s) so we put zero PTP pressure on a
                // body that's just sitting there.
                if isStreaming {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                let intervalNs: UInt64 = 10_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                if Task.isCancelled { return }
                let stillConnected = await MainActor.run {
                    if case .ready = self.ui { return true }
                    if case .streaming = self.ui { return true }
                    return false
                }
                guard stillConnected else { continue }
                await self.refreshSnapshot()
                // Reload choices every 4th tick, they change less often than values.
                if Int.random(in: 0..<4) == 0 {
                    await self.loadChoices()
                }
            }
        }
    }

    // MARK: - Hotkey

    private func startHotkey() {
        hotkey?.stop()
        hotkeyTask?.cancel()
        var config = HoldKeyMonitor.Config()
        if AppSettings.shared.zoomUsesShift {
            // Shift-hold = zoom. Bare modifier → always local;
            // a global Shift trigger would zoom while any app is focused.
            config.triggerModifier = .shift
            config.keyCode = 0x31 // unused for trigger; arrow-gate only
            config.globalScope = false
        } else {
            config.keyCode = AppSettings.shared.zoomKeyCode
            config.globalScope = AppSettings.shared.enableGlobalHotkey
        }
        hotkeyLog.info("starting HoldKeyMonitor (trigger=\(AppSettings.shared.zoomUsesShift ? "Shift" : "key0x\(String(config.keyCode, radix: 16))", privacy: .public), global=\(config.globalScope, privacy: .public))")
        let hk = HoldKeyMonitor(config: config)
        do {
            try hk.start()
            hotkeyLog.info("HoldKeyMonitor.start() OK")
        } catch {
            hotkeyLog.error("HoldKeyMonitor.start() failed: \(String(describing: error), privacy: .public)")
            return
        }
        self.hotkey = hk
        hotkeyTask = Task { [weak self] in
            for await event in hk.events {
                await self?.handleHotkey(event)
            }
        }
    }

    /// Local NSEvent monitor that fires capture on the configured capture key
    /// (default: Return). Only active while a Film Tether window is focused.
    private func startCaptureKeyMonitor() {
        if let monitor = captureKeyMonitor {
            NSEvent.removeMonitor(monitor)
            captureKeyMonitor = nil
        }
        let configured = AppSettings.shared.captureKeyCode
        hotkeyLog.info("installing capture-key monitor (keyCode=0x\(String(configured, radix: 16), privacy: .public))")
        captureKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Verbose: log every keyDown so we can see if the monitor is even firing.
            hotkeyLog.debug("keyDown: code=0x\(String(event.keyCode, radix: 16), privacy: .public) repeat=\(event.isARepeat, privacy: .public)")
            if event.isARepeat { return event }
            // Manual-focus stepping via keyboard: "," = far, "." = near.
            // Bare = fine (1), ⌥ = medium (2), ⌃ = coarse (3). ⌘ is left alone
            // so ⌘, still opens Settings. Only act over live view, and never
            // while a text field is being edited (Settings typing unaffected).
            if let chars = event.charactersIgnoringModifiers, chars == "," || chars == "." {
                if (NSApp.keyWindow?.firstResponder as? NSText) != nil { return event }
                let mods = event.modifierFlags
                if mods.contains(.command) { return event }
                guard self.isLiveViewOn else { return event }
                let near = (chars == ".")
                let step: CameraProperties.ManualFocusStep
                if mods.contains(.control)     { step = near ? .nearLarge : .farLarge }
                else if mods.contains(.option) { step = near ? .nearSmall : .farSmall }
                else                           { step = near ? .nearTiny  : .farTiny }
                hotkeyLog.info("focus key matched, driving \(step.rawValue, privacy: .public)")
                Task { await self.driveManualFocus(step) }
                return nil // consume
            }
            if event.keyCode == AppSettings.shared.captureKeyCode {
                hotkeyLog.info("capture key matched, firing captureNow")
                Task { await self.captureNow() }
                return nil // consume
            }
            return event
        }
    }

    private func handleHotkey(_ event: HoldKeyMonitor.Event) async {
        hotkeyLog.info("HoldKeyMonitor event: \(String(describing: event), privacy: .public)")
        switch event {
        case .pressed:
            // Trigger held (Shift by default) → punch in to 5× sensor zoom.
            // 10× was removed (silently no-ops on this 7D firmware).
            // Remember where we were so the release restores it: holding Shift
            // from 100% used to dump you back at Fit.
            if !previewZoom.engagesCameraPunchIn { zoomBeforeHold = previewZoom }
            await setPreviewZoom(.fiveX)
        case .released:
            await setPreviewZoom(zoomBeforeHold)
        case .arrow(let direction):
            // Arrow nudge moves the zoom rect by ONE FULL RECT STEP per
            // press (matches EOS Utility behavior). Now that zoom is
            // client-side (JPEG crop), the nudge is just a meteringCenter
            // shift, no body interaction, no calibration headaches.
            // Step = 0.2 normalized (1/5 of image dimension, matching the
            // 5x crop rect size). Clamped to [0.1, 0.9] so the rect never
            // crosses the edge.
            await nudgeMeteringCenter(direction)
        }
    }

    private func nudgeMeteringCenter(_ direction: HoldKeyMonitor.ArrowKey) async {
        let f = AppModel.zoomBoxFraction
        let step = f                 // one box-width per press
        let lo = f / 2, hi = 1 - f / 2   // keep the box fully inside the frame
        // The arrow the user pressed is a direction on SCREEN; meteringCenter
        // lives in sensor space. Map through the rotation so pressing Up always
        // moves the box up in the preview, whichever way the frame is turned.
        let screenDelta: CGVector
        switch direction {
        case .up:    screenDelta = CGVector(dx: 0, dy: -step)
        case .down:  screenDelta = CGVector(dx: 0, dy: step)
        case .left:  screenDelta = CGVector(dx: -step, dy: 0)
        case .right: screenDelta = CGVector(dx: step, dy: 0)
        }
        let d = previewRotation.sensorDelta(fromDisplay: screenDelta)
        var c = meteringCenter
        c.x = min(max(c.x + d.dx, lo), hi)
        c.y = min(max(c.y + d.dy, lo), hi)
        meteringCenter = c
        // If the real sensor zoom is engaged, move the punch-in to the new
        // spot too (arrows nudge the live magnified region, like EOS Utility).
        await moveCameraZoomToMeteringCenter()
    }

    private func applyZoom(_ mode: LiveZoom.Mode) async {
        self.zoomMode = mode
        // The goal is a zoom that yields more real pixels from the camera.
        // PRIMARY path is the body's sensor-crop punch-in (eoszoom), a fresh,
        // sharp 1024×680 JPEG of a
        // small sensor region, exactly what EOS Utility does. Client-side
        // JPEG crop is kept ONLY as an automatic fallback if the body refuses
        // the write. The box aims the punch-in via eoszoomposition.
        guard let lz = liveZoom else {
            self.zoomFallbackActive = true   // no camera-side path → client crop
            return
        }
        if mode == .fit {
            await withLVPriority { try? await lz.setZoom(.fit) }
            self.zoomFallbackActive = false
            return
        }
        // .fivex, punch in, THEN move the window to the box. Order matters:
        // Canon's EVF recenters the zoom window when zoom engages, so a
        // position written BEFORE eoszoom=5 is discarded (it doesn't zoom to
        // that spot). Enter magnified mode first, let the body settle,
        // then set eoszoomposition, and re-assert once, because the recenter
        // can land just after our first write.
        let (x, y) = bodyZoomTopLeft()
        self.zoomBodyCenter = (x, y)
        let cameraSideOK: Bool = await withLVPriority {
            do {
                try await lz.setZoom(.fivex)
                try? await Task.sleep(nanoseconds: 180_000_000)
                try await lz.setZoomPosition(x: x, y: y)
                try? await Task.sleep(nanoseconds: 120_000_000)
                try? await lz.setZoomPosition(x: x, y: y)
                return true
            } catch {
                appLog.error("camera-side zoom failed (\(String(describing: error), privacy: .public)); falling back to client crop")
                return false
            }
        }
        // OK → body now streams the magnified frame; handleFrame passes it
        // through untouched (sharp). Not OK → handleFrame client-crops.
        self.zoomFallbackActive = !cameraSideOK
    }

    /// Upper-left corner of the 1/5 punch-in rect in LV-image pixel space,
    /// derived from the normalized box center. `eoszoomposition` wants the
    /// top-left, not the center. Clamped so the rect stays inside the frame.
    private func bodyZoomTopLeft() -> (x: Int, y: Int) {
        // Desired rect top-left in OUTPUT pixels (the box you see), clamped so
        // the box stays in frame, then inverted through the measured line
        // fit_px = origin + eoszoom × slope to get the eoszoomposition value.
        // Invert the measured camera response: eoszoom = (box - offset) × gain,
        // clamped to the camera's range. Lands the zoom center on the box across
        // the reachable area; extreme top/left hit the hardware floor (eoszoom 0).
        let ex = (meteringCenter.x - AppModel.zoomRespOffset.x) * AppModel.zoomRespGain.x
        let ey = (meteringCenter.y - AppModel.zoomRespOffset.y) * AppModel.zoomRespGain.y
        let x = Int(min(max(ex, 0), AppModel.zoomEoszoomMax.x))
        let y = Int(min(max(ey, 0), AppModel.zoomEoszoomMax.y))
        return (x, y)
    }

    // nudgeZoom REMOVED, body refuses positions past a tight bound and
    // the EOS-Utility-style arrow stepping never traversed the full frame.

    // MARK: - Permissions

    func refreshPermissions() {
        self.permissionsState = .init(
            accessibility: Permissions.hasAccessibility,
            inputMonitoring: Permissions.hasInputMonitoring
        )
    }

    func requestAccessibility() { Permissions.requestAccessibility(); refreshPermissions() }
    func requestInputMonitoring() { Permissions.requestInputMonitoring(); refreshPermissions() }
    func openAccessibilityPane() { Permissions.openAccessibilityPane() }
    func openInputMonitoringPane() { Permissions.openInputMonitoringPane() }

    // MARK: - Re-entry after permission grant or first launch

    func enableGlobalHotkey() async {
        guard permissionsState.accessibility && permissionsState.inputMonitoring else { return }
        hotkey?.stop()
        hotkeyTask?.cancel()
        var config = HoldKeyMonitor.Config()
        config.keyCode = 0x31
        config.globalScope = true
        let hk = HoldKeyMonitor(config: config)
        do {
            try hk.start()
        } catch {
            // Permission was revoked between check and start. Leave hotkey nil.
            return
        }
        self.hotkey = hk
        hotkeyTask = Task { [weak self] in
            for await event in hk.events {
                await self?.handleHotkey(event)
            }
        }
    }
}
