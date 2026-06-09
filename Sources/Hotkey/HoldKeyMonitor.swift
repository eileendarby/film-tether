//
//  HoldKeyMonitor.swift
//  FilmTether, Hotkey module
//
//  Hold-to-zoom hotkey monitor for the focus-check feature.
//  Press-and-hold the trigger to send
//  `eoszoom=5` to the camera; release to send `eoszoom=1`. The trigger is
//  either a keyCode (legacy) or a bare modifier via `Config.triggerModifier`
//  (default in-app: Shift = zoom). Arrow keys while held nudge the zoom rect.
//
//  Two scopes:
//    - Local  (config.globalScope == false): NSEvent local monitor, fires only
//                                             when our window is frontmost; no
//                                             special permissions needed.
//    - Global (config.globalScope == true):  CGEventTap on the session event
//                                             tap, fires regardless of focus;
//                                             requires BOTH Accessibility AND
//                                             Input Monitoring on macOS 14+.
//
//  Emits ONE `.pressed` on first non-autorepeat keyDown of the configured key,
//  ONE `.released` on the matching keyUp, and `.arrow(direction)` on each
//  arrow keyDown that occurs *while* the configured key is held. Arrows when
//  the key isn't held are ignored. Autorepeat keyDowns of the configured key
//  are dropped.
//

import Foundation
import AppKit
import CoreGraphics
import Carbon.HIToolbox   // kVK_* constants, clearer than magic numbers

public final class HoldKeyMonitor: @unchecked Sendable {

    // MARK: - Public types

    public enum Event: Sendable {
        case pressed(modifiers: ModifierSet)
        case released
        case arrow(ArrowKey)
    }

    public enum ArrowKey: Sendable {
        case up, down, left, right
    }

    /// A bare modifier used as the hold-to-zoom trigger (Shift = zoom by
    /// default). When `Config.triggerModifier` is set, press/release are detected
    /// from `flagsChanged` transitions of this modifier instead of a keyCode,     /// because modifiers don't emit keyDown/keyUp with a keycode. The configured
    /// `keyCode` is then used ONLY for the arrow-nudge gate.
    public enum TriggerModifier: Sendable { case shift, command, option, control }

    public struct ModifierSet: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let none    = ModifierSet([])
        public static let shift   = ModifierSet(rawValue: 1 << 0)
        public static let command = ModifierSet(rawValue: 1 << 1)
        public static let option  = ModifierSet(rawValue: 1 << 2)
    }

    public struct Config: Sendable {
        /// US-layout key code. 0x31 = Space (kVK_Space). Override for other layouts.
        /// In `triggerModifier` mode this is NOT the trigger, it's only consulted
        /// for the arrow-nudge gate, so leave it at any unused value.
        public var keyCode: CGKeyCode = 0x31
        /// When set, the hold trigger is this bare modifier (via flagsChanged)
        /// rather than `keyCode`. nil → classic keycode trigger.
        public var triggerModifier: TriggerModifier? = nil
        /// `true` → CGEventTap (requires permissions). `false` → NSEvent local monitor.
        public var globalScope: Bool = false
        public init() {}
    }

    public enum PermissionError: Error, LocalizedError {
        case accessibilityDenied
        case inputMonitoringDenied
        case bothDenied

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Global hotkey requires Accessibility permission. Enable it in System Settings → Privacy & Security → Accessibility."
            case .inputMonitoringDenied:
                return "Global hotkey requires Input Monitoring permission. Enable it in System Settings → Privacy & Security → Input Monitoring."
            case .bothDenied:
                return "Global hotkey requires BOTH Accessibility and Input Monitoring permissions. Enable both in System Settings → Privacy & Security."
            }
        }
    }

    // MARK: - Stored config + state

    private let config: Config

    /// Currently-running mode (nil when stopped). Tracked so `stop()` knows
    /// which teardown path to take and so we don't double-`start()`.
    private enum RunMode { case local, global }
    private var runMode: RunMode?

    /// Logical "is our configured hotkey currently held down?", set true by
    /// the first non-autorepeat keyDown matching `config.keyCode`, cleared on
    /// the matching keyUp. Used to (a) suppress duplicate `.pressed` from
    /// autorepeat, (b) gate `.arrow(...)` emission to only-while-held.
    /// Accessed from the CGEventTap callback thread AND the NSEvent main-thread
    /// monitor, so we serialize through `stateLock`.
    private var keyHeld: Bool = false
    private let stateLock = NSLock()

    // MARK: - Local-scope state

    private var localMonitor: Any?  // opaque token returned by NSEvent

    // MARK: - Global-scope state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    /// Signaled by the tap thread once its CFRunLoop is registered and ready
    /// to run; `start()` waits on this so we don't return before the tap is
    /// actually live.
    private let tapReadySemaphore = DispatchSemaphore(value: 0)

    // MARK: - AsyncStream plumbing

    private var continuation: AsyncStream<Event>.Continuation?
    private var lazyStream: AsyncStream<Event>?
    private let streamLock = NSLock()

    // MARK: - Init / public surface

    public init(config: Config = Config()) {
        self.config = config
    }

    deinit {
        // Best-effort teardown; callers should call stop() explicitly because
        // deinit may run off the CFRunLoop thread.
        stopUnsafe()
    }

    /// Lazy single-consumer event stream. The continuation is captured on first
    /// access and reused; later subscribers get the SAME stream (Swift's
    /// AsyncStream is single-consumer by design, which matches our "App layer
    /// only subscribes once" contract from the spec).
    public var events: AsyncStream<Event> {
        streamLock.lock()
        defer { streamLock.unlock() }
        if let existing = lazyStream { return existing }
        let stream = AsyncStream<Event>(bufferingPolicy: .bufferingNewest(64)) { cont in
            self.continuation = cont
        }
        lazyStream = stream
        return stream
    }

    /// Start monitoring. In `globalScope`, throws if either permission is
    /// missing, does NOT prompt the user (call Permissions.request* first).
    public func start() throws {
        guard runMode == nil else { return }   // idempotent

        if config.globalScope {
            // BOTH gates required on macOS 14+.
            let ax  = Permissions.hasAccessibility
            let hid = Permissions.hasInputMonitoring
            switch (ax, hid) {
            case (false, false): throw PermissionError.bothDenied
            case (false, true):  throw PermissionError.accessibilityDenied
            case (true, false):  throw PermissionError.inputMonitoringDenied
            case (true, true):   break
            }
            try startGlobal()
            runMode = .global
        } else {
            startLocal()
            runMode = .local
        }
    }

    /// Stop monitoring and tear down all resources. Idempotent.
    public func stop() {
        stopUnsafe()
    }

    private func stopUnsafe() {
        switch runMode {
        case .local:
            if let token = localMonitor {
                NSEvent.removeMonitor(token)
            }
            localMonitor = nil
        case .global:
            // Disable + invalidate tap; CFRunLoopStop kicks the runloop thread
            // out of CFRunLoopRun() so the pthread exits its body.
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            if let src = runLoopSource, let rl = tapRunLoop {
                CFRunLoopRemoveSource(rl, src, .commonModes)
            }
            if let rl = tapRunLoop {
                CFRunLoopStop(rl)
            }
            eventTap = nil
            runLoopSource = nil
            tapRunLoop = nil
            tapThread = nil
        case nil:
            break
        }
        runMode = nil

        // Reset held-state in case stop() lands between pressed/released.
        stateLock.lock(); keyHeld = false; stateLock.unlock()
    }

    // MARK: - Local-scope implementation

    private func startLocal() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] nsEvent in
            guard let self else { return nsEvent }
            // Modifier-trigger mode (Shift=zoom): press/release ride on
            // flagsChanged. NEVER consume the modifier, Shift must keep
            // working normally for everything else while the app is focused.
            if self.config.triggerModifier != nil, nsEvent.type == .flagsChanged {
                self.handleModifierTransition(down: self.flagsContainTrigger(nsEvent.modifierFlags))
                return nsEvent
            }
            // Swallow the event ONLY if we recognized it as our configured
            // hotkey or as an arrow key delivered while the hotkey is held.
            // Returning nsEvent for an unrecognized keypress to a window with
            // no first-responder for that key triggers AppKit's system beep,             // producing the "error-beep the whole time I'm holding
            // spacebar" symptom. Consume when handled; pass through otherwise.
            let keyCode = CGKeyCode(nsEvent.keyCode)
            // In modifier mode the configured keyCode is NOT ours (Shift is the
            // trigger), so only arrows-while-held are consumed.
            let triggerByKey = (self.config.triggerModifier == nil) && (keyCode == self.config.keyCode)
            let handled = triggerByKey ||
                          (self.arrowKey(for: keyCode) != nil && self.isKeyHeld())
            self.handleNSEvent(nsEvent)
            return handled ? nil : nsEvent
        }
    }

    private func handleNSEvent(_ ev: NSEvent) {
        let keyCode = CGKeyCode(ev.keyCode)
        switch ev.type {
        case .keyDown:
            // NSEvent surfaces autorepeat via `.isARepeat`. In modifier-trigger
            // mode the keyCode is never the trigger, skip the press path.
            if config.triggerModifier == nil, keyCode == config.keyCode {
                if ev.isARepeat { return }      // drop autorepeat
                deliverPressed(modifiers: translate(nsModifiers: ev.modifierFlags))
            } else if let arrow = arrowKey(for: keyCode) {
                // Arrow keys only fire while the configured hotkey is held.
                if isKeyHeld() {
                    deliver(.arrow(arrow))
                }
            }
        case .keyUp:
            if config.triggerModifier == nil, keyCode == config.keyCode {
                deliverReleased()
            }
        default:
            break
        }
    }

    /// Modifier-trigger press/release. `deliverPressed`/`deliverReleased`
    /// self-dedup via `keyHeld`, so repeated flagsChanged (e.g. a second
    /// modifier added) won't double-fire.
    private func handleModifierTransition(down: Bool) {
        if down {
            deliverPressed(modifiers: config.triggerModifier == .shift ? [.shift] : [])
        } else {
            deliverReleased()
        }
    }

    private func flagsContainTrigger(_ ns: NSEvent.ModifierFlags) -> Bool {
        switch config.triggerModifier {
        case .shift:   return ns.contains(.shift)
        case .command: return ns.contains(.command)
        case .option:  return ns.contains(.option)
        case .control: return ns.contains(.control)
        case nil:      return false
        }
    }

    private func flagsContainTrigger(_ cg: CGEventFlags) -> Bool {
        switch config.triggerModifier {
        case .shift:   return cg.contains(.maskShift)
        case .command: return cg.contains(.maskCommand)
        case .option:  return cg.contains(.maskAlternate)
        case .control: return cg.contains(.maskControl)
        case nil:      return false
        }
    }

    // MARK: - Global-scope implementation (CGEventTap + dedicated runloop)

    private func startGlobal() throws {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)   |
            (1 << CGEventType.flagsChanged.rawValue)

        // refcon holds an UNRETAINED pointer to self. We control the lifetime
        // by calling stop() before self is deallocated; passUnretained avoids
        // a retain cycle (CGEventTap → self → tap).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HoldKeyMonitor.tapCallback,
            userInfo: selfPtr
        ) else {
            // tapCreate returns nil if perms were revoked between our check
            // and the call, or if the process can't tap the session.
            throw PermissionError.bothDenied
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.eventTap = tap
        self.runLoopSource = source

        // Spin a dedicated NSThread carrying its own CFRunLoop. Apple's docs
        // for CGEventTap state the tap must be driven by a runloop that's
        // alive for the tap's lifetime; running it on the main loop would
        // couple hotkey latency to SwiftUI redraw cadence. Using NSThread
        // instead of raw pthread because the Foundation lifecycle is cleaner
        // and the underlying runloop semantics are identical.
        let thread = Thread { [weak self] in
            guard let self else { return }
            let rl = CFRunLoopGetCurrent()
            self.tapRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            self.tapReadySemaphore.signal()
            CFRunLoopRun()  // blocks until CFRunLoopStop()
        }
        thread.name = "FilmTether.HoldKeyMonitor.tapRunLoop"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        thread.start()

        // Don't return from start() until the tap is wired up and listening,
        // otherwise an immediate keypress could race the runloop registration.
        _ = tapReadySemaphore.wait(timeout: .now() + .seconds(2))
    }

    /// C-callback bridge. MUST be `@convention(c)`, CGEventTap APIs are
    /// pure-C function pointers and a Swift closure won't bridge.
    private static let tapCallback: CGEventTapCallBack = { _, type, cgEvent, refcon in
        guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
        let monitor = Unmanaged<HoldKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.handleCGEvent(type: type, event: cgEvent)
        // Transparent tap, return the event unchanged; never consume keys.
        // `cgEvent` is autoreleased by the system runloop, so passing it back
        // via passUnretained is correct (no retain change).
        return Unmanaged.passUnretained(cgEvent)
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        // Tap can be disabled by the system (timeout, user-initiated), we
        // get a tapDisabledByTimeout/tapDisabledByUserInput event and must
        // re-enable. Without this, a long Algorithm step or sleep can wedge
        // the tap silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            if config.triggerModifier == nil, keyCode == config.keyCode {
                // Drop autorepeat keyDowns of the configured hotkey.
                let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                if autorepeat != 0 { return }
                deliverPressed(modifiers: translate(cgFlags: event.flags))
            } else if let arrow = arrowKey(for: keyCode) {
                if isKeyHeld() {
                    deliver(.arrow(arrow))
                }
            }
        case .keyUp:
            if config.triggerModifier == nil, keyCode == config.keyCode {
                deliverReleased()
            }
        case .flagsChanged:
            // Modifier-trigger mode (Shift=zoom): press/release ride here.
            // In keycode mode we stay quiet (modifiers are read off keyDown).
            if config.triggerModifier != nil {
                handleModifierTransition(down: flagsContainTrigger(event.flags))
            }
        default:
            break
        }
    }

    // MARK: - Delivery helpers

    private func deliverPressed(modifiers: ModifierSet) {
        stateLock.lock()
        let wasHeld = keyHeld
        keyHeld = true
        stateLock.unlock()
        // Belt-and-suspenders: if some upstream layer ever bypasses the
        // autorepeat-drop, don't emit a duplicate `.pressed`.
        guard !wasHeld else { return }
        deliver(.pressed(modifiers: modifiers))
    }

    private func deliverReleased() {
        stateLock.lock()
        let wasHeld = keyHeld
        keyHeld = false
        stateLock.unlock()
        guard wasHeld else { return }   // only emit if matched a prior press
        deliver(.released)
    }

    private func deliver(_ event: Event) {
        continuation?.yield(event)
    }

    private func isKeyHeld() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return keyHeld
    }

    // MARK: - Translation helpers

    private func translate(nsModifiers flags: NSEvent.ModifierFlags) -> ModifierSet {
        var result: ModifierSet = []
        if flags.contains(.shift)   { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option)  { result.insert(.option) }
        return result
    }

    private func translate(cgFlags flags: CGEventFlags) -> ModifierSet {
        var result: ModifierSet = []
        if flags.contains(.maskShift)     { result.insert(.shift) }
        if flags.contains(.maskCommand)   { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        return result
    }

    /// Map US-layout arrow keycodes to `ArrowKey`. Keycodes are layout-
    /// independent on macOS for the arrow cluster (they live in the dedicated
    /// arrow block), so hardcoding is safe across QWERTY/Dvorak/Colemak.
    private func arrowKey(for keyCode: CGKeyCode) -> ArrowKey? {
        switch Int(keyCode) {
        case kVK_UpArrow:    return .up        // 0x7E
        case kVK_DownArrow:  return .down      // 0x7D
        case kVK_LeftArrow:  return .left      // 0x7B
        case kVK_RightArrow: return .right     // 0x7C
        default:             return nil
        }
    }
}
