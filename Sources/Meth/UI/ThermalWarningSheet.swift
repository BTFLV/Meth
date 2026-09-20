import SwiftUI
import AppKit

public struct ThermalWarningView: View {
    var onAcknowledge: () -> Void
    var onCancel: () -> Void

    public init(onAcknowledge: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onAcknowledge = onAcknowledge
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)

            Text("Closed-Lid Mode Safety Notice")
                .font(.headline)

            Text("The Mac may continue running while closed and can generate heat or consume significant battery power.\n\nPlease place your MacBook on a flat, well-ventilated surface. Do not place an actively running closed laptop into an enclosed bag or backpack.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("I Understand") {
                    onAcknowledge()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 380)
    }
}

public final class ThermalWarningWindowController: NSWindowController {
    public static func show(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        let controller = ThermalWarningWindowController()

        let view = ThermalWarningView(
            onAcknowledge: {
                controller.window?.close()
                onConfirm()
            },
            onCancel: {
                controller.window?.close()
                onCancel()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Meth — Safety Notice"
        window.contentView = NSHostingView(rootView: view)
        window.level = .floating
        controller.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

