import SwiftUI
import Camera
import Scan

struct ExposureBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
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
            kelvinStepper()
            imageFormatPicker()
            Divider().frame(height: 28)
            focusGroup()
            Divider().frame(height: 28)
            captureButton()
            liveViewToggle()
            rotateButton()
            peakingToggleButton()
            boxToggleButton()
            zoomToggleButton()
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
            Label(model.previewRotation.displayName, systemImage: "rotate.right")
                .labelStyle(.titleAndIcon)
                // Fixed width so the neighbouring buttons don't shuffle as the
                // angle changes, sized for the widest label: "270°" measures
                // 29pt at the 13pt system font, plus a 15pt icon and ~5pt of
                // Label spacing ≈ 49pt. The rest is slack.
                .frame(width: 56, alignment: .leading)
        }
        .help("Rotate the live preview 90° clockwise (Cmd-R; Cmd-Shift-R goes counter-clockwise). Display only — the camera and the saved files are untouched.")
    }

    @ViewBuilder
    private func boxToggleButton() -> some View {
        Button {
            model.showMeteringOverlay.toggle()
        } label: {
            Label(
                model.showMeteringOverlay ? "Box ON" : "Box OFF",
                systemImage: model.showMeteringOverlay ? "plus.viewfinder" : "viewfinder"
            )
            .labelStyle(.titleAndIcon)
        }
        .help("Show/hide the zoom-target crosshair box (default on). Click anywhere on live view to move it.")
        .disabled(!model.isLiveViewOn)
    }

    @ViewBuilder
    private func peakingToggleButton() -> some View {
        Button {
            model.focusPeakingEnabled.toggle()
        } label: {
            Label(
                model.focusPeakingEnabled ? "Peaking ON" : "Peaking OFF",
                systemImage: model.focusPeakingEnabled ? "scope" : "circle.dotted"
            )
            .labelStyle(.titleAndIcon)
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

    @ViewBuilder
    private func kelvinStepper() -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("White Balance").font(.caption2).foregroundStyle(.secondary)
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
            .help("Color temperature (active when WB mode is Color Temperature)")
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
    private func focusGroup() -> some View {
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
            Text(model.isLiveViewOn ? "Stop Live View" : "Start Live View")
                .frame(width: 104)
        }
        .keyboardShortcut("l", modifiers: [.command])
        .help("Toggle live preview (Cmd-L)")
    }

    private func writableForCurrentMode(_ prop: String) -> Bool {
        CameraProperties.isWritable(prop: prop, inMode: model.snapshot.mode)
    }
}
