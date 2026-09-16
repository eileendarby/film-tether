import SwiftUI
import Camera
import Scan

struct ExposureBar: View {
    @EnvironmentObject var model: AppModel

    /// The layout for this width, chosen by MainView from measured piece
    /// widths (see `ToolbarLayout`), so one bar is rendered per frame rather
    /// than a couple of dozen candidates measured.
    ///
    /// Capture, live view, zoom and rotation keep their text at every size —
    /// they're the controls you reach for constantly, and the last two double
    /// as state readouts whose value (the angle, the percentage) can't be
    /// shown by an icon — but they do drop to the second row after the
    /// toggles. The manual-focus stepper is never unfolded: it is two lines
    /// tall and read as the bar growing a row, so it stays a menu.
    var layout: ToolbarLayout = .row(labelled: ExposureBar.toggleCount)

    /// Render one piece alone, offscreen, so MainView can measure it. Nil
    /// for the real bar.
    var measuring: Piece? = nil

    enum Piece: Equatable {
        /// Pickers, dividers, the focus menu.
        case fixed
        /// One item, labelled or as an icon.
        case item(Int, labelled: Bool)
    }

    /// Items in bar order: the four always-labelled buttons, then the eight
    /// toggles.
    static let fixedButtonCount = 4
    static let toggleCount = 8
    static let itemCount = fixedButtonCount + toggleCount
    static let compactable: [Bool] = Array(repeating: false, count: fixedButtonCount)
        + Array(repeating: true, count: toggleCount)

    /// Whether toggle `slot` (0…7) shows its label.
    private func labelled(_ slot: Int) -> Bool {
        let item = Self.fixedButtonCount + slot
        if case .item(let i, let l) = measuring, i == item { return l }
        return layout.isLabelled(item: item, compactable: Self.compactable)
    }

    var body: some View {
        switch measuring {
        case .fixed:
            HStack(spacing: 10) { fixedPart }
        case .item(let i, _):
            item(i)
        case nil:
            switch layout {
            case .row:
                HStack(spacing: 10) {
                    fixedPart
                    items(0..<Self.itemCount)
                }
            case .wrapped(let moved, _):
                let split = Self.itemCount - moved
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        fixedPart
                        items(0..<split)
                    }
                    HStack(spacing: 10) {
                        items(split..<Self.itemCount)
                    }
                }
            }
        }
    }

    /// Everything before the items.
    @ViewBuilder
    private var fixedPart: some View {
        pickers
        Divider().frame(height: 28)
        focusGroup()
        Divider().frame(height: 28)
    }

    @ViewBuilder
    private func items(_ range: Range<Int>) -> some View {
        ForEach(Array(range), id: \.self) { i in
            item(i)
        }
    }

    @ViewBuilder
    private func item(_ i: Int) -> some View {
        switch i {
        case 0: captureButton()
        case 1: liveViewToggle()
        case 2: zoomToggleButton()
        case 3: rotateButton()
        case 4: invertToggleButton()
        case 5: monoToggleButton()
        case 6: whiteBalanceButton()
        case 7: autoCropButton()
        case 8: cropToggleButton()
        case 9: peakingToggleButton()
        case 10: boxToggleButton()
        case 11: archiveToggleButton()
        default: EmptyView()
        }
    }

    @ViewBuilder
    private var pickers: some View {
            menuPicker(
                label: "ISO",
                currentLabel: model.snapshot.isoLabel,
                choices: model.isoChoices,
                propName: "iso",
                widthHint: 80,     // "ISO 12800" measured from screenshot
                isDisabled: !writableForCurrentMode("iso"),
                onPick: { raw in Task { await model.setISO(raw) } }
            )
            shutterPicker()
            menuPicker(
                label: "Aperture",
                currentLabel: model.snapshot.apertureLabel,
                choices: model.apertureChoices,
                propName: "aperture",
                widthHint: 56,     // "f/2.8" widest; "f/22"/"f/32" shorter
                isDisabled: !writableForCurrentMode("aperture"),
                onPick: { raw in Task { await model.setAperture(raw) } }
            )
            whiteBalancePicker()
            kelvinStepper()
            imageFormatPicker()
    }

    /// Show or put away the archive tray on the right. Always enabled: the
    /// tray is about the archive, not the camera, so it works without one.
    @ViewBuilder
    private func archiveToggleButton() -> some View {
        Button {
            model.showArchiveTray.toggle()
        } label: {
            adaptiveLabel(slot: 7, 
                model.showArchiveTray ? "Archive ON" : "Archive OFF",
                systemImage: model.showArchiveTray ? "sidebar.trailing" : "sidebar.trailing",
                width: 96
            )
        }
        .help("Show or hide the archive tray: where scans are filed and how the sends are going. Cmd-Shift-T.")
    }

    /// Label for a toggle that collapses to its icon in a narrow window.
    ///
    /// The icons carry the on/off state on their own (filled vs outline, and so
    /// on), so collapsing the text doesn't cost you the ability to read the
    /// current state — which is the whole point of these buttons. Every one of
    /// them has a `.help` tooltip naming it, which is what you get back when
    /// the text is gone.
    @ViewBuilder
    private func adaptiveLabel(
        slot: Int, _ title: String, systemImage: String, width: CGFloat
    ) -> some View {
        if !labelled(slot) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .frame(width: width, alignment: .leading)
        }
    }

    /// Click rotates the preview a quarter turn clockwise; the label doubles as
    /// the current-rotation readout. Counter-clockwise lives on Cmd-Shift-R —
    /// the toolbar is already near the window's minimum width, so a second
    /// button isn't worth the pixels.
    @ViewBuilder
    private func rotateButton() -> some View {
        Button {
            model.rotatePreviewRight()
        } label: {
            Label(model.rotationLabel, systemImage: "rotate.right")
                .labelStyle(.titleAndIcon)
                // Fixed width so the neighbouring buttons don't shuffle as the
                // angle changes. Sized for the widest label, which is now a
                // straightened one — "268.5°" rather than "270°".
                .frame(width: 74, alignment: .leading)
        }
        .disabled(!model.isLiveViewOn)
        .help(model.previewFineRotation == 0
              ? "Rotate the live preview 90° clockwise (Cmd-R; Cmd-Shift-R goes counter-clockwise). Display only — the camera and the saved files are untouched."
              : String(format: "Rotated 90° at a time, plus %.1f° of straightening from the crop box's rotate handles. Cmd-R turns; Cmd-Shift-R goes back. Option-click to clear the straightening.",
                       model.previewFineRotation))
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded {
            model.resetFineRotation()
        })
    }

    /// Negative / positive toggle. The label names what you're currently
    /// looking at, matching how the rotation button reads.
    @ViewBuilder
    private func invertToggleButton() -> some View {
        let inverted = model.previewAdjustments.invert
        Button {
            model.toggleInvert()
        } label: {
            adaptiveLabel(slot: 0, inverted ? "Positive" : "Negative",
                          systemImage: inverted ? "circle.righthalf.filled.inverse" : "film",
                          width: 82)
        }
        .help("Invert the preview so a negative shows as the positive image (Cmd-I). Judging framing and focus on an inverted image is guesswork. Display only — the captured RAW is still the negative.")
        .disabled(!model.isLiveViewOn)
    }

    /// Colour / B&W preview toggle.
    @ViewBuilder
    private func monoToggleButton() -> some View {
        let mono = model.previewAdjustments.monochrome
        Button {
            model.toggleMonochrome()
        } label: {
            adaptiveLabel(slot: 1, mono ? "B&W" : "Color",
                          systemImage: mono ? "circle.lefthalf.filled" : "paintpalette",
                          width: 62)
        }
        .help("Show the preview in black and white (Cmd-B). Raw pixels off a B&W negative carry no useful colour, so judging exposure and focus is easier without it. Display only — the camera and the saved files are untouched.")
        .disabled(!model.isLiveViewOn)
    }

    /// Arms the eyedropper; the next click on the preview sets white balance.
    /// Shows the sampled state so it's obvious a correction is active.
    @ViewBuilder
    private func whiteBalanceButton() -> some View {
        let armed = model.isPickingWhiteBalance
        let isSet = model.previewAdjustments.whiteBalance != nil
        Button {
            model.toggleWhiteBalancePicker()
        } label: {
            adaptiveLabel(slot: 2, 
                armed ? "Pick…" : (isSet ? "WB set" : "WB"),
                systemImage: armed ? "eyedropper.halffull" : "eyedropper",
                width: 68
            )
        }
        .help(model.previewAdjustments.invert
              ? "Unavailable while the preview is inverted: with a positive on screen the film base is the darkest part of the picture, not the brightest, which invites clicking the wrong spot. Switch to Negative to sample."
              : model.previewZoom == .actual
              ? "Unavailable at 100%, where the pane shows a window onto the frame rather than the whole of it, so a click doesn't identify the pixel underneath it. Sample at Fit or 500%."
              : "Click here, then click the unexposed film base in the preview to neutralise its colour cast. The blue/amber half is sent to the camera as a colour temperature, so it reaches the captured RAW; the green/magenta half, which a Kelvin control can't express, is corrected on the preview. Click again to refine — each sample corrects what's left. Clear the preview part from the Preview menu.")
        .disabled(!model.canPickWhiteBalance)
    }

    /// Recalculates every time it's pressed, and holds no state of its own.
    /// Pressing it again after nudging the box by hand starts over, which is the
    /// point of having it separate from the toggle.
    @ViewBuilder
    private func autoCropButton() -> some View {
        Button {
            model.runAutoCrop()
        } label: {
            adaptiveLabel(slot: 3, "Auto-Crop", systemImage: "crop", width: 96)
        }
        .help("Find the negative under the lens and put an adjustable crop box on it. Pressing it again re-detects from scratch. Uses the film format from the last confirmed crop to check the result, and to build one if detection can't be trusted.")
        .disabled(!model.isLiveViewOn || model.previewZoom != .fit)
    }

    /// Whether the crop is interactive. Labelled with the state it is in rather
    /// than the state it would move to, matching every other toggle here.
    @ViewBuilder
    private func cropToggleButton() -> some View {
        let editing = model.isCropEditing
        Button {
            if editing { model.applyCrop() } else { model.editCrop() }
        } label: {
            adaptiveLabel(slot: 4, editing ? "Crop ON" : "Crop OFF",
                          systemImage: editing ? "crop.rotate" : "rectangle.dashed",
                          width: 90)
        }
        .help(editing
              ? "Crop is being adjusted: drag its corners or edge handles, or the band just outside them to straighten the negative. Turning it off fixes the box in place and hands the interface back, so the eyedropper and the metering box can be reached again — Return does the same. Delete clears the crop."
              : "Crop is fixed, drawn as a thin outline. Turn it back on to adjust the box.")
        .disabled(!model.isCropActive)
    }

    @ViewBuilder
    private func boxToggleButton() -> some View {
        Button {
            model.showMeteringOverlay.toggle()
        } label: {
            adaptiveLabel(slot: 6, 
                model.showMeteringOverlay ? "Box ON" : "Box OFF",
                systemImage: model.showMeteringOverlay ? "plus.viewfinder" : "viewfinder",
                width: 74
            )
        }
        .help("Show/hide the zoom-target crosshair box (default on). Click anywhere on live view to move it.")
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func peakingToggleButton() -> some View {
        Button {
            model.focusPeakingEnabled.toggle()
        } label: {
            adaptiveLabel(slot: 5, 
                model.focusPeakingEnabled ? "Peaking ON" : "Peaking OFF",
                systemImage: model.focusPeakingEnabled ? "scope" : "circle.dotted",
                width: 102
            )
        }
        .help("Toggle focus peaking overlay (Cmd-P). Cmd-Shift-P cycles color.")
        .disabled(!model.isLiveViewOn)
    }

    /// Cycles Fit → 100% → 500%. The label is the current zoom, with Fit
    /// carrying its live percentage.
    @ViewBuilder
    private func zoomToggleButton() -> some View {
        let isZoomed = model.previewZoom.engagesCameraPunchIn
        Button {
            Task { await model.cyclePreviewZoom() }
        } label: {
            Label(
                model.previewZoomLabel,
                systemImage: isZoomed ? "magnifyingglass.circle.fill" : "magnifyingglass.circle"
            )
            .labelStyle(.titleAndIcon)
            // Sized for the widest label, "Fit (100%)", so the button doesn't
            // twitch as the percentage changes during a window resize.
            .frame(width: 92, alignment: .leading)
        }
        .help("Preview zoom, click to cycle: Fit (scaled to the pane) → 100% (one frame pixel per point) → 500% (the camera's own sensor punch-in, real detail rather than an upscale). Hold Shift for momentary 500% and it returns to where you were. Drag the overlay rectangle to choose the punch-in location BEFORE zooming.")
        .disabled(!model.isLiveViewOn)
    }

    // MARK: - Pickers

    @ViewBuilder
    private func menuPicker(
        label: String,
        currentLabel: String,
        choices: [String],
        propName: String,
        widthHint: CGFloat,
        isDisabled: Bool,
        onPick: @escaping (String) -> Void
    ) -> some View {
        let transformed = PropertyLabels.transform(choices: choices, forProperty: propName)
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Menu {
                ForEach(transformed, id: \.raw) { item in
                    Button(item.label) { onPick(item.raw) }
                }
            } label: {
                // Belt-and-suspenders fixed sizing:
                //   1. ZStack with Color.clear forces label SIZE = widthHint
                //   2. Text gets explicit frame too so it can't push the
                //      ZStack wider than widthHint
                //   3. Outer Menu .frame overrides Menu's chrome padding
                // Earlier ZStack-only was incomplete because Menu's outer
                // chrome adds variable padding that varied with content.
                ZStack(alignment: .leading) {
                    Color.clear.frame(width: widthHint, height: 18)
                    Text(currentLabel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: widthHint, alignment: .leading)
                }
            }
            .menuIndicator(.hidden)
            .frame(width: widthHint + 6)   // tight outer frame, just enough for SwiftUI Menu chrome
            .disabled(isDisabled || choices.isEmpty)
            .opacity(isDisabled ? 0.5 : 1.0)
            .help(isDisabled
                  ? "Locked by current mode (\(model.snapshot.modeLabel))"
                  : "Current: \(currentLabel), tap to change")
        }
        .frame(width: widthHint + 6)
    }

    /// Shutter picker. Picker label shows whatever value the body reports
    /// (often "Auto" in Av/P modes). The live metered value lives in the
    /// status footer (📏), single source of truth, no duplication.
    @ViewBuilder
    private func shutterPicker() -> some View {
        let primaryLabel = model.snapshot.shutterLabel
        VStack(alignment: .leading, spacing: 1) {
            Text("Shutter").font(.caption2).foregroundStyle(.secondary)
            let transformed = PropertyLabels.transform(choices: model.shutterChoices, forProperty: "shutterspeed")
            Menu {
                ForEach(transformed, id: \.raw) { item in
                    Button(item.label) { Task { await model.setShutter(item.raw) } }
                }
            } label: {
                ZStack(alignment: .leading) {
                    Color.clear.frame(width: 60, height: 18)
                    Text(primaryLabel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 60, alignment: .leading)
                }
            }
            .menuIndicator(.hidden)
            .frame(width: 60 + 6)   // "1/8000" widest
            .disabled(!writableForCurrentMode("shutterspeed") || model.shutterChoices.isEmpty)
            .opacity(writableForCurrentMode("shutterspeed") ? 1.0 : 0.5)
            .help(writableForCurrentMode("shutterspeed")
                  ? "Current: \(primaryLabel), tap to change"
                  : "Locked by current mode (\(model.snapshot.modeLabel))")
        }
        .frame(width: 60 + 6)
    }

    /// White-balance **mode**. Without this the app could set a colour
    /// temperature but never the mode that makes it apply, so a body sitting in
    /// a PC-set custom white balance was stuck there — every frame heavily
    /// cast, with nothing in the UI to show why or to change it.
    @ViewBuilder
    private func whiteBalancePicker() -> some View {
        menuPicker(
            label: "WB Mode",
            currentLabel: model.snapshot.whiteBalanceLabel,
            choices: model.whiteBalanceChoices,
            propName: "whitebalance",
            widthHint: 118,    // "Custom Whitebalance: PC-1" truncates; tooltip has it
            isDisabled: model.whiteBalanceChoices.isEmpty,
            onPick: { raw in Task { await model.setWhiteBalanceMode(raw) } }
        )
    }

    @ViewBuilder
    private func kelvinStepper() -> some View {
        // Only meaningful in Color Temperature mode; every other mode ignores
        // the value outright. Greyed out rather than silently inert, and
        // changing the temperature also switches the body into the mode so the
        // number means what it says.
        let active = model.kelvinIsActive
        VStack(alignment: .leading, spacing: 1) {
            Text("Temperature").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(model.snapshot.kelvinLabel)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .frame(width: 52, alignment: .leading)    // "10000K" measured
                Stepper("", value: Binding<Int>(
                    get: { model.snapshot.whiteBalanceKelvin ?? 5500 },
                    set: { v in Task { await model.setWhiteBalanceKelvin(v) } }
                ), in: 2500...10000, step: 100)
                    .labelsHidden()
            }
            .opacity(active ? 1.0 : 0.5)
            .help(active
                  ? "Colour temperature the body is using."
                  : "The body is in \(model.snapshot.whiteBalanceLabel) mode, which ignores this value. Changing it switches the body to Color Temperature so it takes effect.")
        }
    }

    @ViewBuilder
    private func imageFormatPicker() -> some View {
        let transformed = PropertyLabels.transform(choices: model.imageFormatChoices, forProperty: "imageformat")
        VStack(alignment: .leading, spacing: 1) {
            Text("Format").font(.caption2).foregroundStyle(.secondary)
            Menu {
                ForEach(transformed, id: \.raw) { item in
                    Button(item.label) {
                        Task { await model.setImageFormat(item.raw) }
                    }
                }
            } label: {
                ZStack(alignment: .leading) {
                    Color.clear.frame(width: 120, height: 18)
                    Text(model.snapshot.imageFormatLabel)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 120, alignment: .leading)
                }
            }
            .menuIndicator(.hidden)
            .frame(width: 120 + 6)   // tail-truncates if string exceeds; tooltip shows full
            .disabled(model.imageFormatChoices.isEmpty)
            .help("Image format. Current: \(model.snapshot.imageFormatLabel)")
        }
        .frame(width: 120 + 6)
    }

    // MARK: - Focus group

    /// Six manual-drive buttons (3 toward Near, 3 toward Far) for fine
    /// adjustment without touching the lens, a way to affect focus remotely.
    /// Manual focus stepping (Far / Near with three magnitudes each).
    /// AF button removed; autofocus is optional for this workflow.
    /// Empirically the 7D's autofocusdrive
    /// PTP op wedges the body's EVF subsystem within a few uses, even
    /// after removing the cancelautofocus chaser, the body eventually
    /// hangs on capture_preview with no recovery short of power cycle.
    /// Better to lose the feature than to make the user power-cycle the
    /// 7D every few minutes. Manual focus via the step buttons + lens-side
    /// AF + capture's own AF lifecycle still works.
    @ViewBuilder
    /// Manual focus: six step buttons and a position counter when there's
    /// room, one menu when there isn't. The two rows of small controls are
    /// the widest thing in the bar after the pickers, and on a copy stand
    /// focus is set once and left, so the compact bar folds them away. The
    /// keys (, and . with Option/Control) work either way.
    private func focusGroup() -> some View {
        // Always the menu. The six-button stepper is two lines tall and made
        // the bar look like it had grown a second row; the keys and the menu
        // do the same job at one line.
        focusMenu()
    }

    private func focusMenu() -> some View {
        let position = model.focusStepPosition > 0 ? "+\(model.focusStepPosition)" : "\(model.focusStepPosition)"
        return Menu {
            Button("Far, coarse step  ⌃,") { Task { await model.driveManualFocus(.farLarge) } }
            Button("Far, medium step  ⌥,") { Task { await model.driveManualFocus(.farSmall) } }
            Button("Far, fine step  ,") { Task { await model.driveManualFocus(.farTiny) } }
            Button("Near, fine step  .") { Task { await model.driveManualFocus(.nearTiny) } }
            Button("Near, medium step  ⌥.") { Task { await model.driveManualFocus(.nearSmall) } }
            Button("Near, coarse step  ⌃.") { Task { await model.driveManualFocus(.nearLarge) } }
            Divider()
            Button("Reset position counter (now \(position))") { model.resetFocusPosition() }
        } label: {
            Label("Focus", systemImage: "plusminus.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Manual focus steps (lens in AF, live view on). Position counter: \(position). Keys: , and . step fine; with Option medium; with Control coarse.")
        .disabled(!model.isLiveViewOn)
    }

    private func focusStepper() -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("Focus").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(model.focusStepPosition > 0 ? "+\(model.focusStepPosition)" : "\(model.focusStepPosition)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(model.focusStepPosition == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .help("Relative focus position since last reset, running total of step magnitudes (Near +, Far −). The camera can't report absolute focus, and 1·2·3 are fine/medium/coarse presets, so this is a directional tracker, not physical distance.")
                Button { model.resetFocusPosition() } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .help("Reset the focus position counter to 0 (does not move the lens)")
                .disabled(!model.isLiveViewOn)
            }
            HStack(spacing: 2) {
                focusButton("⟪⟪⟪", help: "Focus FAR, coarse step (−3). Big jump toward infinity.  ⌨ ⌃,", step: .farLarge)
                focusButton("⟪⟪",  help: "Focus far, medium step (−2).  ⌨ ⌥,", step: .farSmall)
                focusButton("⟪",   help: "Focus far, fine step (−1). Smallest nudge toward infinity.  ⌨ ,", step: .farTiny)
                focusButton("⟫",   help: "Focus near, fine step (+1). Smallest nudge toward the subject.  ⌨ .", step: .nearTiny)
                focusButton("⟫⟫",  help: "Focus near, medium step (+2).  ⌨ ⌥.", step: .nearSmall)
                focusButton("⟫⟫⟫", help: "Focus NEAR, coarse step (+3). Big jump toward the subject.  ⌨ ⌃.", step: .nearLarge)
            }
        }
    }

    @ViewBuilder
    private func focusButton(_ glyph: String, help: String, step: CameraProperties.ManualFocusStep) -> some View {
        Button {
            Task { await model.driveManualFocus(step) }
        } label: {
            Text(glyph)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 24)   // was 32; 6 buttons × 8px saved = 48px room recovered
        }
        .controlSize(.small)
        .help(help)
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func captureButton() -> some View {
        Button {
            Task { await model.captureNow() }
        } label: {
            Label("Capture", systemImage: "camera.shutter.button")
                .labelStyle(.titleAndIcon)
        }
        .keyboardShortcut(.return, modifiers: [.command, .shift])
        .buttonStyle(.borderedProminent)
        // No explicit .tint(), let SwiftUI pick up the OS accent color
        // (System Settings → Appearance → Accent). Adapts to user
        // preference automatically; respects light/dark mode.
        .controlSize(.regular)   // was .large, shrunk to fit the toolbar
        .help(model.isLiveViewOn
              ? "Capture and download a RAW (Cmd-Shift-Return or just Return)"
              : "Start live view first, capture requires LV up so exposure matches preview")
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func liveViewToggle() -> some View {
        Button {
            Task {
                if model.isLiveViewOn {
                    await model.stopLiveView()
                } else {
                    await model.startLiveView()
                }
            }
        } label: {
            // A lamp rather than a word: the state is the thing you glance at
            // between frames, and colour reads faster than reading. Still the
            // current state and not the action it performs, matching every
            // other toggle here — the menu item stays phrased as a command,
            // which is the macOS convention for menus.
            //
            // The label doesn't change with the state, so the button never
            // changes width and its neighbours never shuffle.
            HStack(spacing: 7) {
                Circle()
                    .fill(model.isLiveViewOn ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 11, height: 11)
                Text("Live")
                    .foregroundStyle(model.isLiveViewOn ? .primary : .secondary)
            }
            .frame(width: 48)
        }
        .keyboardShortcut("l", modifiers: [.command])
        .help(model.isLiveViewOn
              ? "Live preview is running. Click to stop it (Cmd-L)."
              : "Live preview is off. Click to start it (Cmd-L).")
    }

    private func writableForCurrentMode(_ prop: String) -> Bool {
        CameraProperties.isWritable(prop: prop, inMode: model.snapshot.mode)
    }
}
