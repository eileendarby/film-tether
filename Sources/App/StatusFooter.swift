import SwiftUI
import Camera

struct StatusFooter: View {
    @EnvironmentObject var model: AppModel

    /// MMM d, HH:mm:ss, readable but compact for the status bar.
    static let cameraClockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 16) {
            connectionBadge()
            Text(model.snapshot.modeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Camera mode (set by the body's mode dial)")
            // Optional metered shutter display, opt-in via Settings → Footer
            // display. Shows only when the body has emitted a value (after
            // capture or a settings change). Blank when not available.
            // Default OFF because the value is sporadic on this body.
            if AppSettings.shared.showMeteredShutter, let metered = model.snapshot.meteredShutter {
                Text("📏 \(PropertyLabels.shutter(metered))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Most recent metered shutter value the body has emitted. Doesn't update in real time on some bodies, only after a capture or settings change.")
            }
            if AppSettings.shared.showBatteryIndicator, model.snapshot.battery != "—" {
                Text("🔋 \(model.snapshot.batteryLabel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let cameraTime = model.snapshot.cameraDateTime {
                let drift = abs(cameraTime.timeIntervalSinceNow)
                let isStale = drift > 300  // 5 min off = needs sync
                Button {
                    Task { await model.syncCameraClock() }
                } label: {
                    HStack(spacing: 4) {
                        Text("🕒")
                            .font(.caption)
                        Text(Self.cameraClockFormatter.string(from: cameraTime))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isStale ? .red : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(isStale
                      ? "Camera clock is off by \(Int(drift))s vs host, click to sync"
                      : "Camera clock matches host, click to re-sync")
            }
            // FPS hidden by default; surface only when EOS_DEBUG=1 for diagnostics.
            if model.isLiveViewOn && ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1" {
                Text(String(format: "%.1f fps", model.snapshot.fps))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.zoomMode != .fit {
                Text("Zoom: \(model.zoomMode.rawValue)x\(model.zoomFallbackActive ? " (sw)" : "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let last = model.lastCapture {
                Text("Last: \(last)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private func connectionBadge() -> some View {
        let (color, text): (Color, String) = {
            switch model.ui {
            case .disconnected: return (.gray, "Disconnected")
            case .enumerating: return (.yellow, "Connecting…")
            case .ready: return (.green, "Ready")
            case .streaming: return (.green, "Streaming")
            case .error: return (.red, "Error")
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption)
        }
    }
}
