import AppKit

/// Cleans up the menu bar AppKit actually ends up with.
///
/// SwiftUI's `commands` builder says what to *add*; the finished menu bar is
/// that merged with the standard macOS menus, and the merge leaves debris no
/// SwiftUI API can reach:
///
/// - **Separators with nothing between them.** Each `CommandGroup` gets its own
///   separator whether or not the group has any content, so emptied groups
///   collapse into doubled separators, and a group at the end of a menu leaves a
///   trailing one. Both draw as blank space.
/// - **Duplicated system items.** AppKit injects "Start Dictation…" and
///   "Emoji & Symbols" into Edit, and does it more than once — three copies of
///   Emoji & Symbols in this app.
/// - **Commands for features that don't exist.** "Toggle Sidebar" is added even
///   with no sidebar to toggle, and lands in Help of all places.
/// - **Empty menus.** A menu with no items opens and instantly closes again,
///   and can't be reopened — it reads as a broken app rather than an empty menu.
///
/// The tidy re-runs every time the menu bar is clicked rather than once at
/// launch, because SwiftUI rebuilds menus whenever the state behind a title
/// changes — several titles here are state-dependent ("Hide/Show Zoom-Area
/// Overlay", the current rotation angle) — and each rebuild brings the debris
/// back. Re-running is cheap and self-healing.
enum MenuBarTidy {

    /// Actions for features this app doesn't have, whose menu items macOS adds
    /// anyway.
    ///
    /// Only items that exist *before* a menu displays can be removed this way —
    /// see the note on `onTidied`. Window tabbing is handled at the source
    /// instead, for exactly that reason.
    private static let unwantedActions: Set<Selector> = [
        Selector(("toggleSidebar:")),
    ]

    static func install() {
        // Film Tether is a single-window app: there is one live view, tied to
        // one camera over one USB connection, so a second tab could only ever
        // show the same thing. This has to be switched off at the source rather
        // than filtered out below, because AppKit inserts "Hide Tab Bar" and
        // "Show All Tabs" while the menu is being displayed — after every hook
        // this class can install. Measured: with tabbing on, they appear in View
        // no matter what the tidy does; with it off, they never appear at all.
        // It also keeps "Merge All Windows" and the rest out of the Window menu,
        // which otherwise grows from 4 items to 16.
        NSWindow.allowsAutomaticWindowTabbing = false

        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            guard let menu = note.object as? NSMenu else { return }
            // Individual menus post this too, and they have to be handled:
            // AppKit fills a submenu just before *it* displays, not when the bar
            // is first clicked, so anything inserted at that point is invisible
            // to a pass that only runs on the menu bar.
            if menu === NSApp.mainMenu {
                tidy(menu, isMenuBar: true)
            } else {
                tidy(menu)
            }
            onTidied?()
        }
        // Also after tracking ends: anything AppKit adds between "about to
        // display" and the menu actually closing is only observable here.
        NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
        ) { _ in onTidied?() }
        tidy(NSApp.mainMenu, isMenuBar: true)
    }

    /// Hook for the debug dump, so a report can be taken from the menu bar as it
    /// actually stands rather than as it stands at launch.
    ///
    /// Finding out *when* the menu bar can be inspected truthfully took three
    /// tries, each one disproved by leaving window tabbing deliberately enabled
    /// and checking whether the report noticed:
    ///
    /// 1. At launch, after `update()` on every submenu — reported a clean View
    ///    menu. Wrong.
    /// 2. On the menu bar's `didBeginTracking` — still clean. Wrong.
    /// 3. On each submenu's `didBeginTracking` — still clean. Wrong.
    /// 4. On `didEndTracking` — "Hide Tab Bar" and "Show All Tabs" finally
    ///    appear.
    ///
    /// So AppKit inserts them between a menu being asked to display and the
    /// menu closing, which is after every hook available here. That's why
    /// tabbing is disabled at the source, and why a report that hasn't had a
    /// menu opened in front of it proves nothing.
    static var onTidied: (() -> Void)?

    static func tidy(_ menu: NSMenu?, isMenuBar: Bool = false) {
        guard let menu else { return }
        for item in menu.items {
            if let sub = item.submenu { tidy(sub) }
        }
        if !isMenuBar {
            removeUnwanted(menu)
            removeDuplicates(menu)
            normalizeSeparators(menu)
        }
        // The menu bar's own items are the top-level titles; a title whose menu
        // has nothing in it is worse than no title at all.
        if isMenuBar {
            for item in menu.items where item.submenu?.items.isEmpty == true {
                menu.removeItem(item)
            }
        }
    }

    private static func removeUnwanted(_ menu: NSMenu) {
        for item in menu.items where item.action.map(unwantedActions.contains) == true {
            menu.removeItem(item)
        }
    }

    /// Drop repeats of the same command, keeping the first. Matches on title and
    /// action together so two genuinely different items that happen to share a
    /// title survive.
    private static func removeDuplicates(_ menu: NSMenu) {
        var seen = Set<String>()
        for item in menu.items where !item.isSeparatorItem {
            let key = "\(item.title)\u{1}\(item.action.map(NSStringFromSelector) ?? "")"
            if !seen.insert(key).inserted { menu.removeItem(item) }
        }
    }

    /// A separator is only meaningful between two real items.
    private static func normalizeSeparators(_ menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        var i = menu.items.count - 1
        while i > 0 {
            if menu.items[i].isSeparatorItem, menu.items[i - 1].isSeparatorItem {
                menu.removeItem(at: i)
            }
            i -= 1
        }
    }
}
