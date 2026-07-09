import SwiftUI
import AppKit
import Camera

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            captureTab()
                .tabItem { Label("Capture", systemImage: "camera.shutter.button") }

            liveViewTab()
                .tabItem { Label("Live View", systemImage: "viewfinder") }

            cameraTab()
                .tabItem { Label("Camera", systemImage: "camera") }

            hotkeyTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }

            aboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
        .padding()
    }

    // MARK: - Live View

    @ViewBuilder
    private func liveViewTab() -> some View {
        Form {
            Section("Focus peaking") {
                HStack {
                    Picker("Detection mode", selection: $settings.focusPeakingMode) {
                        ForEach(FocusPeaking.Mode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("""
                            Edges: Sobel boundary detector. Lights up sharp transitions, face edges, building lines, hard outlines. General purpose; works on any subject.

                            Grain (default for film scanning): high-pass filter tuned to 1-3 pixel features. Suppresses smooth gradients + large edges; only lights up fine texture. When scanning film, the grain comes into focus before larger details, when grain stops twinkling, focus is locked in.

                            If you don't see a difference between modes on your current scene, try Grain on a high-grain stock or push Sensitivity higher.
                            """)
                }

                HStack {
                    Text("Sensitivity")
                    Slider(value: $settings.focusPeakingIntensity, in: 1.0...10.0, step: 0.5)
                    Text(String(format: "%.1f", settings.focusPeakingIntensity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Section("Peaking color") {
                colorSwatchGrid()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func colorSwatchGrid() -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(FocusPeaking.PeakColor.allCases, id: \.self) { color in
                colorSwatch(color)
            }
        }
    }

    @ViewBuilder
    private func colorSwatch(_ color: FocusPeaking.PeakColor) -> some View {
        let rgb = color.swatchRGB
        let isSelected = settings.focusPeakingColor == color
        Button {
            settings.focusPeakingColor = color
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                    .frame(height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                                    lineWidth: isSelected ? 3 : 1)
                    )
                Text(color.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Use \(color.displayName) for focus peaking highlights")
    }

    // MARK: - Camera

    @ViewBuilder
    private func cameraTab() -> some View {
        Form {
            Section("Camera clock") {
                if let cameraTime = model.snapshot.cameraDateTime {
                    HStack {
                        Text("Camera reports")
                        Spacer()
                        Text(Self.fullClockFormatter.string(from: cameraTime))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    let drift = cameraTime.timeIntervalSinceNow
                    let absDrift = abs(drift)
                    HStack {
                        Text("Drift vs host")
                        Spacer()
                        Text(driftString(drift))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(absDrift > 60 ? .red : .secondary)
                    }
                } else {
                    Text("No clock reading yet, connect a camera to read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Sync camera clock to host now") {
                    Task { await model.syncCameraClockLocal() }
                }
                .disabled(model.snapshot.cameraDateTime == nil)
                Toggle("Auto-sync on connect", isOn: $settings.autoSyncClockOnConnect)
            }

            Section("Footer display") {
                Toggle("Show battery indicator", isOn: $settings.showBatteryIndicator)
                Toggle("Show last metered shutter", isOn: $settings.showMeteredShutter)
                Text("The metered shutter value only updates sporadically on this body (LV preview is real-time but the numeric readout isn't).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("EXIF time zone correction") {
                HStack {
                    Text("Offset")
                    Spacer()
                    Picker("", selection: $settings.cameraTZOffsetMinutes) {
                        Text("0").tag(0)
                        Text("+60 min").tag(60)
                        Text("+120 min").tag(120)
                        Text("-60 min").tag(-60)
                        Text("-120 min").tag(-120)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .help("""
                            Added to host UTC before syncing the camera's internal clock. Used to dial out the drift caused by the camera's own time-zone menu setting differing from your host's time zone.

                            Common case: camera on PST while host is on PDT → set +60.

                            Long-term fix lives on the camera: Menu → Setup → Time Zone → match your zone, enable DST. Then this offset can stay at 0.
                            """)
                }
            }
        }
        .formStyle(.grouped)
    }

    static let fullClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f
    }()

    private func driftString(_ drift: TimeInterval) -> String {
        let abs = Swift.abs(drift)
        let sign = drift >= 0 ? "+" : "-"
        if abs < 60 { return "\(sign)\(Int(abs))s" }
        if abs < 3600 { return "\(sign)\(Int(abs / 60))m \(Int(abs.truncatingRemainder(dividingBy: 60)))s" }
        let h = Int(abs / 3600)
        let m = Int((abs.truncatingRemainder(dividingBy: 3600)) / 60)
        return "\(sign)\(h)h \(m)m"
    }

    // MARK: - Capture

    @ViewBuilder
    private func captureTab() -> some View {
        Form {
            Section("Capture folder") {
                HStack {
                    Text(settings.captureFolder.path)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { chooseCaptureFolder() }
                }
                Text("Captured files land here exactly as the camera produced them, no re-encoding, with the camera's real extension (.CR2, .CR3, .JPG…). Set the camera-side image quality to RAW and you get the full sensor data; RAW+JPEG saves both files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Filename pattern") {
                TextField("", text: $settings.filenamePattern)
                    .font(.system(.body, design: .monospaced))
                Text("Tokens: {ymd} = yyyyMMdd, {hms} = HHmmss, {seq} = zero-padded session counter, {ext} = the camera file's own extension (CR2, CR3, JPG…). A literal extension in the pattern is corrected to the real one at save time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Preview: \(previewFilename())")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Reuse the canonical resolver (incl. its path-safety sanitization) so the
    /// preview always matches what capture actually writes.
    private func previewFilename() -> String {
        CameraCapture.resolveFilename(pattern: settings.filenamePattern, timestamp: Date(), sequence: 1)
    }

    private func chooseCaptureFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.captureFolder
        panel.prompt = "Choose"
        panel.message = "Pick a folder for captured RAW files"
        if panel.runModal() == .OK, let url = panel.url {
            settings.setCaptureFolder(url)
        }
    }

    // MARK: - Hotkeys

    @ViewBuilder
    private func hotkeyTab() -> some View {
        Form {
            Section("Capture") {
                Picker("Trigger key", selection: $settings.captureKeyCode) {
                    ForEach(KeyCodeLabel.common, id: \.code) { item in
                        Text(item.label).tag(item.code)
                    }
                }
                Text("Default: Space. Tap once to capture. ⌘Return also triggers from any menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Focus-check zoom (hold)") {
                Toggle("Hold Shift to zoom", isOn: $settings.zoomUsesShift)
                if !settings.zoomUsesShift {
                    Picker("Hold key", selection: $settings.zoomKeyCode) {
                        ForEach(KeyCodeLabel.common, id: \.code) { item in
                            Text(item.label).tag(item.code)
                        }
                    }
                }
                Text(settings.zoomUsesShift
                     ? "Hold Shift over live view to punch in 5×, real sensor zoom, sharp enough to focus. Release to fit. Drag the box first to choose where it zooms; arrow keys nudge it while held. (Shift-zoom is always window-local.)"
                     : "Hold the chosen key to zoom 5×, release to fit. Arrow keys nudge the zoom rectangle while held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global hotkey scope") {
                Toggle("Enable global hotkey", isOn: $settings.enableGlobalHotkey)
                Text("When ON, hotkeys fire even while another app is frontmost. Requires Accessibility + Input Monitoring permissions. When OFF, hotkeys only fire when Film Tether's window is focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.enableGlobalHotkey {
                    HStack {
                        permissionRow("Accessibility", granted: model.permissionsState.accessibility) {
                            model.requestAccessibility()
                        }
                        permissionRow("Input Monitoring", granted: model.permissionsState.inputMonitoring) {
                            model.requestInputMonitoring()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(_ label: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(label).font(.caption)
            if !granted {
                Button("Request") { request() }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - About

    @ViewBuilder
    private func aboutTab() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Film Tether")
                .font(.title2)
            Text("Tethered control for compatible cameras over USB, built around libgphoto2.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("Supported cameras", destination: AppInfo.supportedCamerasURL)
                .font(.caption)
            Spacer()
        }
        .padding(.top, 24)
    }
}
