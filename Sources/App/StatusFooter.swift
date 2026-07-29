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
            // Reconstructed from the stored offset and re-rendered each second,
            // so it ticks along with the system clock. Showing the raw stored
            // timestamp instead left it frozen at whatever the last read said,
            // which drifted visibly out of sync — during live view especially,
            // where snapshot refreshes are suppressed to keep the USB pipe free.
            if let offset = model.snapshot.cameraClockOffset {
                let drift = abs(offset)
                let isStale = drift > 300  // 5 min off = needs sync
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button {
                        Task { await model.syncCameraClock() }
                    } label: {
                        HStack(spacing: 4) {
                            Text("🕒")
                                .font(.caption)
                            Text(Self.cameraClockFormatter.string(
                                from: context.date.addingTimeInterval(offset)
                            ))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isStale ? .red : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                // Measured at connect and at each sync, then advanced with the
                // host clock. The camera only reports its clock once per
                // session (the driver caches it), so this can't be re-read
                // live — but the camera keeps time to about a second a day, so
                // the reading stays trustworthy.
                .help(isStale
                      ? "Camera clock was off by \(Int(drift))s vs host when last read, click to sync"
                      : "Camera clock matches host (within \(Int(drift))s when last read), click to re-sync")
            }
            // FPS hidden by default; surface only when EOS_DEBUG=1 for diagnostics.
            if model.isLiveViewOn && ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1" {
                Text(String(format: "%.1f fps", model.snapshot.fps))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Only worth footer space when the preview isn't showing the plain
            // fitted frame; "(sw)" flags that the body refused the punch-in and
            // we're upscaling a crop host-side instead of showing real detail.
            if model.isLiveViewOn, model.previewZoom != .fit {
                Text("Zoom: \(model.previewZoomLabel)\(model.zoomFallbackActive ? " (sw)" : "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.previewAdjustments.invert {
                Text("Positive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Preview is inverted to show the positive image. The captured RAW is still the negative.")
            }
            if model.previewAdjustments.monochrome {
                Text("B&W")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Preview is being shown in black and white. Saved files are unaffected.")
            }
            if let wb = model.previewAdjustments.whiteBalance {
                Text(String(format: "WB %.2f/%.2f/%.2f", wb.red, wb.green, wb.blue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Host-side white-balance gains (R/G/B) sampled from the preview. Saved files are unaffected.")
            }
            Spacer()
            // Transient feedback for the eyedropper — a refused sample would
            // otherwise look like a click that simply did nothing.
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
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
