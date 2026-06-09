//
//  Permissions.swift
//  FilmTether, Hotkey module
//
//  Wraps the two macOS privacy gates required for a global hotkey on macOS 14+:
//    - Accessibility       (AXIsProcessTrustedWithOptions)
//    - Input Monitoring    (IOHIDCheckAccess / IOHIDRequestAccess)
//
//  Local-scope monitoring (NSEvent.addLocalMonitorForEvents) needs neither, //  these checks only matter when HoldKeyMonitor.Config.globalScope == true.
//
//  Note: CGEventTap on macOS 14+ requires BOTH Accessibility AND Input
//  Monitoring; Apple split these in macOS 10.15+ and enforcement tightened in
//  Sonoma. Both prompts must fire on first launch.
//

import Foundation
import AppKit
import ApplicationServices  // AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt
import IOKit
import IOKit.hid            // IOHIDCheckAccess, IOHIDRequestAccess, kIOHIDRequestTypeListenEvent

public enum Permissions {

    // MARK: - Accessibility

    /// Returns `true` if this process is currently in the Accessibility allow-list.
    /// Non-prompting, safe to call on any thread, any frequency.
    public static var hasAccessibility: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// Triggers the system Accessibility prompt if we're not already trusted.
    /// User must click "Open System Settings" and toggle the app on; the trust
    /// state does not flip until they do, and (in practice) the process must
    /// be relaunched before `hasAccessibility` returns `true`.
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Input Monitoring (HID listen-event)

    /// Returns `true` if this process has been granted Input Monitoring.
    /// `IOHIDCheckAccess` is non-prompting; pair with `requestInputMonitoring`.
    public static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the system Input Monitoring prompt. Like Accessibility, the
    /// answer doesn't take effect until the user toggles and we relaunch.
    public static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - Settings deep-links

    /// Open System Settings → Privacy & Security → Accessibility.
    /// URL scheme works on macOS 13+ and the renamed-in-14 "System Settings".
    public static func openAccessibilityPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Open System Settings → Privacy & Security → Input Monitoring.
    public static func openInputMonitoringPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
