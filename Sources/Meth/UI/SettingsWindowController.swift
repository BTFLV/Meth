import AppKit
import SwiftUI

/// The single Settings window.
///
/// Meth is an `LSUIElement` agent app, so it never builds the standard application menu
/// that installs SwiftUI's `showSettingsWindow:` action. Routing "Settings…" through that
/// action therefore did nothing at all — the menu item looked enabled and simply never
/// opened a window. (The selector name also differs before macOS 14, where it is
/// `showPreferencesWindow:`, so even a non-agent app would have needed a version check.)
///
/// Owning the window directly removes both problems and keeps the "exactly one settings
/// window, refocused on repeated invocations" behaviour the old comment promised.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meth Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()

        let controller = SettingsWindowController(window: window)
        window.delegate = controller
        shared = controller

        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Dropped so the next open builds a fresh view (and re-reads Launch-at-Login and
        // Closed-Lid support status via `onAppear`) instead of showing stale values.
        Self.shared = nil
    }
}
