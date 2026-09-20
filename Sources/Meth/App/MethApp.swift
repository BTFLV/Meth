import SwiftUI
import AppKit

@main
struct MethApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The single Settings window for this menu-bar-only app. SwiftUI manages showing an
    // existing instance and focusing it on repeated invocations; `MenuBarController` opens
    // it via the standard `showSettingsWindow:` action so no second, custom window
    // controller is needed.
    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
