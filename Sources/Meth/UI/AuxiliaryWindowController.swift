import AppKit
import SwiftUI

/// Presents the app's short-lived modal-style dialogs (the "Until…" time picker and the
/// Closed-Lid safety notice).
///
/// It exists because both dialogs previously had the same two defects:
///
/// 1. **No owner.** Each `static func show()` created an `NSWindowController` in a local
///    variable and returned. The controller survived only through an accidental retain
///    cycle (controller → window → hosting view → SwiftUI closure → controller), which in
///    turn meant it was never deallocated after the window closed. Controllers are now
///    held in `liveControllers` for exactly as long as their window is on screen, and the
///    view's closures reference the controller weakly so nothing is leaked afterwards.
///
/// 2. **The close button did nothing.** Dismissing a dialog with the red close button ran
///    neither the confirm nor the cancel callback. For the safety notice that was a real
///    correctness problem: closing the window left "Enable Closed-Lid Mode by default"
///    switched on without the warning ever having been acknowledged. A close that the
///    caller did not initiate is now reported through `onCloseWithoutAction`.
@MainActor
final class AuxiliaryWindowController: NSWindowController, NSWindowDelegate {
    private static var liveControllers: Set<AuxiliaryWindowController> = []

    private var onCloseWithoutAction: (() -> Void)?
    private var didResolve = false

    /// - Parameters:
    ///   - onCloseWithoutAction: run if the window closes without `dismiss()` having been
    ///     called first, i.e. the user clicked the close button. Treated as a cancel.
    ///   - content: builds the SwiftUI content; receives a `dismiss` closure that closes
    ///     the window without triggering `onCloseWithoutAction`.
    static func present<Content: View>(
        title: String,
        size: NSSize,
        onCloseWithoutAction: @escaping () -> Void,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let controller = AuxiliaryWindowController(window: window)
        controller.onCloseWithoutAction = onCloseWithoutAction

        // Weak, so the hosting view's closures never keep the controller alive; the
        // registry below is the single owner.
        let dismiss: () -> Void = { [weak controller] in
            controller?.dismiss()
        }

        window.title = title
        window.delegate = controller
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content(dismiss))
        window.setContentSize(size)
        window.center()

        liveControllers.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window after the caller has already handled the interaction itself.
    func dismiss() {
        didResolve = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        let wasUnresolved = !didResolve
        didResolve = true
        let callback = onCloseWithoutAction
        onCloseWithoutAction = nil
        Self.liveControllers.remove(self)
        if wasUnresolved {
            callback?()
        }
    }
}
