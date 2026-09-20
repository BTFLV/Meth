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

@MainActor
public enum ThermalWarningWindowController {
    /// Closing the window with its close button counts as *not* acknowledging the warning
    /// and runs `onCancel`, so the caller never proceeds on an unacknowledged notice.
    public static func show(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        var hasAnswered = false

        AuxiliaryWindowController.present(
            title: "Meth — Safety Notice",
            size: NSSize(width: 380, height: 300),
            onCloseWithoutAction: {
                guard !hasAnswered else { return }
                hasAnswered = true
                onCancel()
            }
        ) { dismiss in
            ThermalWarningView(
                onAcknowledge: {
                    hasAnswered = true
                    dismiss()
                    onConfirm()
                },
                onCancel: {
                    hasAnswered = true
                    dismiss()
                    onCancel()
                }
            )
        }
    }
}

