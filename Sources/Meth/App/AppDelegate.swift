import AppKit
import MethCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a menu bar accessory application (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        // Perform fail-safe startup recovery in case of previous ungraceful shutdown
        SessionManager.shared.performStartupRecovery()

        // Initialize menu bar status item and UI
        self.menuBarController = MenuBarController()
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
}

