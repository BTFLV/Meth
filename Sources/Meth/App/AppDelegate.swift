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

    public func applicationWillTerminate(_ notification: Notification) {
        // Ensure all assertions and privileged states are restored
        SessionManager.shared.stopSession()
    }
}

