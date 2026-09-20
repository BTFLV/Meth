import AppKit

/// AppKit entry point.
///
/// Meth used to run on the SwiftUI `App` lifecycle with a `Settings` scene, and opened it
/// through `NSApp.sendAction(Selector("showSettingsWindow:"))`. That action is not
/// reliably available to an `LSUIElement` (`.accessory`) app — it is installed by the
/// standard application menu, which an agent app never builds — and its selector name
/// additionally changed between macOS releases (`showPreferencesWindow:` before macOS 14).
/// The result was a "Settings…" menu item that silently did nothing.
///
/// Meth now owns its settings window outright (see `SettingsWindowController`), so opening
/// it is a plain, version-independent AppKit call.
@main
enum MethMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // `NSApplication.delegate` is a weak reference, so the delegate is kept alive by
        // this local binding for as long as `run()` does not return -- i.e. the whole
        // process lifetime.
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
