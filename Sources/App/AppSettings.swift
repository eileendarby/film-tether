import Foundation
import SwiftUI

/// Persisted app settings, backed by UserDefaults.
///
/// Folder picks are stored as security-scoped bookmark data so they survive both relaunches
/// and (eventually) sandboxing. Even though we're unsandboxed today, using bookmarks now
/// future-proofs against an App Store path without churn.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys
    private enum Key {
        static let captureFolderBookmark = "captureFolderBookmark"
        static let filenamePattern = "filenamePattern"
        static let captureKeyCode = "captureKeyCode"
        static let zoomKeyCode = "zoomKeyCode"
        static let zoomUsesShift = "zoomUsesShift"
        static let enableGlobalHotkey = "enableGlobalHotkey"
        static let hotkeyMappingVersion = "hotkeyMappingVersion"
        static let focusPeakingColor = "focusPeakingColor"
        static let focusPeakingMode = "focusPeakingMode"
        static let focusPeakingIntensity = "focusPeakingIntensity"
        static let autoSyncClockOnConnect = "autoSyncClockOnConnect"
        static let cameraTZOffsetMinutes = "cameraTZOffsetMinutes"
        static let focusPeakingEnabled = "focusPeakingEnabled"
        static let showMeteringOverlay = "showMeteringOverlay"
        static let showBatteryIndicator = "showBatteryIndicator"
        static let showMeteredShutter = "showMeteredShutter"
    }

    // MARK: - Defaults

    /// Default capture destination: `~/Pictures/Film Tether/`.
    static var defaultCaptureFolder: URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return pics.appendingPathComponent("Film Tether")
    }

    /// `{ext}` resolves to the extension of the file the camera actually
    /// produced (CR2 on a 7D, CR3 on an R5, JPG for JPEG quality). Patterns
    /// with a hardcoded literal extension (older installs stored ".CR2") get
    /// the extension corrected at save time too, the name never lies about
    /// the bytes inside.
    static let defaultFilenamePattern = "IMG_{ymd}_{hms}_{seq}.{ext}"

    /// Default capture key: Space (US keycode 0x31). (Was Return until remapped
    /// so the space bar triggers capture.)
    static let defaultCaptureKeyCode: UInt16 = 0x31

    /// Fallback zoom key when `zoomUsesShift` is OFF: Space (US keycode 0x31).
    /// Default trigger is the Shift modifier (see `zoomUsesShift`).
    static let defaultZoomKeyCode: UInt16 = 0x31

    /// Current hotkey-mapping migration version. Bump to force a one-time
    /// re-default of the hotkey keys for existing installs whose stored prefs
    /// predate a mapping change. v2 = Shift-zoom / Space-capture.
    static let currentHotkeyMappingVersion = 2

    // MARK: - Capture folder (security-scoped bookmark)

    /// Resolved capture folder. Falls back to `defaultCaptureFolder` if no bookmark is set
    /// or the bookmark is unresolvable.
    @Published private(set) var captureFolder: URL = AppSettings.defaultCaptureFolder

    /// Set a new capture folder; persists as a security-scoped bookmark.
    func setCaptureFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Key.captureFolderBookmark)
            captureFolder = url
        } catch {
            // Bookmark creation can fail for non-existent or inaccessible paths.
            // Fall back to plain URL persistence as a last resort.
            defaults.set(url.path, forKey: Key.captureFolderBookmark + ".path")
            captureFolder = url
        }
    }

    private func loadCaptureFolder() {
        if let bookmark = defaults.data(forKey: Key.captureFolderBookmark) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = url.startAccessingSecurityScopedResource()
                captureFolder = url
                if isStale {
                    setCaptureFolder(url) // refresh bookmark
                }
                return
            }
        }
        // Plain-path fallback
        if let path = defaults.string(forKey: Key.captureFolderBookmark + ".path") {
            captureFolder = URL(fileURLWithPath: path)
            return
        }
        captureFolder = Self.defaultCaptureFolder
    }

    // MARK: - Filename pattern

    @Published var filenamePattern: String {
        didSet { defaults.set(filenamePattern, forKey: Key.filenamePattern) }
    }

    // MARK: - Hotkeys

    @Published var captureKeyCode: UInt16 {
        didSet { defaults.set(Int(captureKeyCode), forKey: Key.captureKeyCode) }
    }

    @Published var zoomKeyCode: UInt16 {
        didSet { defaults.set(Int(zoomKeyCode), forKey: Key.zoomKeyCode) }
    }

    /// When ON (default), hold-to-zoom is triggered by the Shift modifier
    /// instead of `zoomKeyCode`. Shift-zoom is always window-local, a bare
    /// global modifier would zoom while any app is focused.
    @Published var zoomUsesShift: Bool {
        didSet { defaults.set(zoomUsesShift, forKey: Key.zoomUsesShift) }
    }

    @Published var enableGlobalHotkey: Bool {
        didSet { defaults.set(enableGlobalHotkey, forKey: Key.enableGlobalHotkey) }
    }

    // MARK: - Focus peaking

    @Published var focusPeakingColor: FocusPeaking.PeakColor {
        didSet { defaults.set(focusPeakingColor.rawValue, forKey: Key.focusPeakingColor) }
    }

    @Published var focusPeakingMode: FocusPeaking.Mode {
        didSet { defaults.set(focusPeakingMode.rawValue, forKey: Key.focusPeakingMode) }
    }

    @Published var focusPeakingIntensity: Double {
        didSet { defaults.set(focusPeakingIntensity, forKey: Key.focusPeakingIntensity) }
    }

    // MARK: - Camera clock

    /// Push host time → camera the moment connection becomes ready. Default ON
    /// so the date is set automatically. This was OFF earlier as a precaution
    /// against a suspected wedge-trigger, but that correlation was never proven.
    /// If a wedge recurs, flip this toggle off in Settings.
    @Published var autoSyncClockOnConnect: Bool {
        didSet { defaults.set(autoSyncClockOnConnect, forKey: Key.autoSyncClockOnConnect) }
    }

    /// Manual correction to `datetimeutc` sync to compensate for the camera's
    /// internal TZ menu. Background: the 7D's `datetimeutc` widget writes the
    /// camera's UTC clock; the body then derives EXIF DateTimeOriginal as
    /// `internal_utc + camera_tz_menu_offset`. If the camera's TZ menu doesn't
    /// match the host's TZ, EXIF drifts by the delta. An exact 1-hour gap was
    /// observed with the camera on PST (no DST) while the host was on PDT.
    /// libgphoto2 doesn't expose a widget for the camera TZ menu, so we can't
    /// read it. Workaround: this offset is added to host UTC before writing
    /// `datetimeutc`, letting users dial out the delta without touching the
    /// camera's menu.
    ///
    /// Units: minutes. +60 = sync 1 hour ahead of host UTC (use this when
    /// camera is on PST while host is on PDT). -60 = sync 1 hour behind.
    @Published var cameraTZOffsetMinutes: Int {
        didSet { defaults.set(cameraTZOffsetMinutes, forKey: Key.cameraTZOffsetMinutes) }
    }

    /// Whether focus peaking is enabled. Persisted across launches so the last
    /// peaking on/off state is restored on the next launch.
    @Published var focusPeakingEnabled: Bool {
        didSet { defaults.set(focusPeakingEnabled, forKey: Key.focusPeakingEnabled) }
    }

    /// Whether the metering / zoom rect overlay is shown. Default ON; like the
    /// Cmd-P toggle, this state should just stay on across launches.
    @Published var showMeteringOverlay: Bool {
        didSet { defaults.set(showMeteringOverlay, forKey: Key.showMeteringOverlay) }
    }

    /// Show the battery percentage in the footer. Default OFF for the common
    /// case of a body that stays plugged in.
    @Published var showBatteryIndicator: Bool {
        didSet { defaults.set(showBatteryIndicator, forKey: Key.showBatteryIndicator) }
    }

    /// Show the most-recent metered shutter speed in the footer when one is
    /// available. Default OFF because the value can only update sporadically
    /// (LV-meter rarely fires shutterspeed events; only first capture wakes
    /// the meter). Opt-in for users who want to glance at the body's last
    /// metered reading even knowing it's not real-time.
    @Published var showMeteredShutter: Bool {
        didSet { defaults.set(showMeteredShutter, forKey: Key.showMeteredShutter) }
    }

    // MARK: - Init

    private init() {
        var storedPattern = defaults.string(forKey: Key.filenamePattern) ?? Self.defaultFilenamePattern
        // One-time migration: installs that saved the pre-{ext} default keep
        // its hardcoded ".CR2" in UserDefaults. Save-time extension correction
        // makes it harmless, but move them to the new default so the Settings
        // preview reflects reality. Custom patterns are left untouched.
        if storedPattern == "IMG_{ymd}_{hms}_{seq}.CR2" {
            storedPattern = Self.defaultFilenamePattern
            defaults.set(storedPattern, forKey: Key.filenamePattern)
        }
        self.filenamePattern = storedPattern
        // One-time hotkey-mapping migration. Existing installs have a stored
        // captureKeyCode (Return) and no zoomUsesShift, so just changing the
        // static defaults wouldn't move them. Bumping the version forces the
        // new Shift-zoom / Space-capture mapping ONCE; the user can re-edit
        // afterward and it sticks (the migration won't run again).
        let storedMappingVersion = defaults.integer(forKey: Key.hotkeyMappingVersion)
        let needsHotkeyMigration = storedMappingVersion < Self.currentHotkeyMappingVersion
        if needsHotkeyMigration {
            defaults.set(Int(Self.defaultCaptureKeyCode), forKey: Key.captureKeyCode)
            defaults.set(true, forKey: Key.zoomUsesShift)
            defaults.set(false, forKey: Key.enableGlobalHotkey) // Shift-zoom is local-only
            defaults.set(Self.currentHotkeyMappingVersion, forKey: Key.hotkeyMappingVersion)
        }
        let storedCapture = defaults.object(forKey: Key.captureKeyCode) as? Int
        self.captureKeyCode = UInt16(storedCapture ?? Int(Self.defaultCaptureKeyCode))
        let storedZoom = defaults.object(forKey: Key.zoomKeyCode) as? Int
        self.zoomKeyCode = UInt16(storedZoom ?? Int(Self.defaultZoomKeyCode))
        // zoomUsesShift defaults true when unset (migration also sets it).
        self.zoomUsesShift = (defaults.object(forKey: Key.zoomUsesShift) as? Bool) ?? true
        self.enableGlobalHotkey = defaults.bool(forKey: Key.enableGlobalHotkey)
        let storedColor = defaults.string(forKey: Key.focusPeakingColor) ?? ""
        self.focusPeakingColor = FocusPeaking.PeakColor(rawValue: storedColor) ?? .cyan
        let storedMode = defaults.string(forKey: Key.focusPeakingMode) ?? ""
        // Default .grain; the primary use case is film scanning where grain
        // detection is the right signal. Previous default was .edges because
        // grain tuning was wrong; tuning now produces a usable visual baseline.
        self.focusPeakingMode = FocusPeaking.Mode(rawValue: storedMode) ?? .grain
        let storedIntensity = defaults.object(forKey: Key.focusPeakingIntensity) as? Double
        self.focusPeakingIntensity = storedIntensity ?? 3.0
        // Default-true. First launch sees no key, UserDefaults.bool returns
        // false by default which would silently disable a wanted feature.
        // Treat missing-key as ON.
        if defaults.object(forKey: Key.autoSyncClockOnConnect) == nil {
            self.autoSyncClockOnConnect = true
            defaults.set(true, forKey: Key.autoSyncClockOnConnect)
        } else {
            self.autoSyncClockOnConnect = defaults.bool(forKey: Key.autoSyncClockOnConnect)
        }
        self.cameraTZOffsetMinutes = (defaults.object(forKey: Key.cameraTZOffsetMinutes) as? Int) ?? 0
        // Both default-true when never set before; the overlay and peaking
        // should stay on like Cmd-P and be remembered across launches.
        if defaults.object(forKey: Key.focusPeakingEnabled) == nil {
            self.focusPeakingEnabled = false  // default OFF first launch; remembered after toggle
            defaults.set(false, forKey: Key.focusPeakingEnabled)
        } else {
            self.focusPeakingEnabled = defaults.bool(forKey: Key.focusPeakingEnabled)
        }
        if defaults.object(forKey: Key.showMeteringOverlay) == nil {
            self.showMeteringOverlay = true   // default ON; can be toggled
            defaults.set(true, forKey: Key.showMeteringOverlay)
        } else {
            self.showMeteringOverlay = defaults.bool(forKey: Key.showMeteringOverlay)
        }
        // Default OFF for the common plugged-in case; opt-in via Settings.
        self.showBatteryIndicator = defaults.bool(forKey: Key.showBatteryIndicator)
        // Default OFF, value is sporadic on this body; opt-in.
        self.showMeteredShutter = defaults.bool(forKey: Key.showMeteredShutter)
        loadCaptureFolder()
    }
}

/// Friendly labels for common US-layout keycodes shown in the Settings UI.
enum KeyCodeLabel {
    static let common: [(code: UInt16, label: String)] = [
        (0x24, "Return"),
        (0x31, "Space"),
        (0x30, "Tab"),
        (0x33, "Delete"),
        (0x35, "Escape"),
        (0x03, "F"),
        (0x06, "Z"),
        (0x0C, "Q"),
        (0x0D, "W"),
        (0x0E, "E"),
    ]

    static func label(for code: UInt16) -> String {
        common.first(where: { $0.code == code })?.label ?? String(format: "0x%02X", code)
    }
}
