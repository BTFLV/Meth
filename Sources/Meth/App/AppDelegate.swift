import AppKit
import MethCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu bar accessory application (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Two copies of Meth (e.g. one in Downloads and one in Applications) would share the
        // system-wide sleep setting and Meth's shared state; this copy's startup recovery
        // could even undo the other one's active Closed-Lid session. Checked before anything
        // touches that state.
        if isAnotherInstanceRunning() {
            let alert = NSAlert()
            alert.messageText = "Meth Is Already Running"
            alert.informativeText = "Another copy of Meth is already running. Use its icon in the menu bar, or quit it before opening this copy."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Perform fail-safe startup recovery in case of previous ungraceful shutdown
        SessionManager.shared.performStartupRecovery()

        // Initialize menu bar status item and UI
        self.menuBarController = MenuBarController()
    }

    /// Opening Meth again (from Finder, Spotlight, or Launchpad) while it is running would
    /// otherwise do nothing visible, for instance when its menu bar icon is hidden behind
    /// the notch. Show Settings instead.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if menuBarController != nil && !flag {
            SettingsWindowController.show()
        }
        return true
    }

    // Session cleanup involves an async privileged operation, so termination is deferred
    // until it actually completes rather than risking the process exiting mid-cleanup.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await SessionManager.shared.stopSession()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != ownPID && !$0.isTerminated }
    }
}
