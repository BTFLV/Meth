import SwiftUI
import AppKit
import MethCore

public struct UntilTimePickerView: View {
    @State private var selectedDate: Date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    var onConfirm: (Date) -> Void
    var onCancel: () -> Void

    public init(onConfirm: @escaping (Date) -> Void, onCancel: @escaping () -> Void) {
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 20) {
            Text("Keep Awake Until")
                .font(.headline)

            DatePicker(
                "End Time",
                selection: $selectedDate,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.stepperField)
            .labelsHidden()

            Text("Session will keep your Mac awake until the selected time.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start Session") {
                    let cal = Calendar.current
                    let hour = cal.component(.hour, from: selectedDate)
                    let min = cal.component(.minute, from: selectedDate)
                    let target = SessionDuration.nextDate(hour: hour, minute: min)
                    onConfirm(target)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

public final class UntilTimeWindowController: NSWindowController {
    private var completion: ((Date?) -> Void)?

    public static func show(completion: @escaping (Date?) -> Void) {
        let controller = UntilTimeWindowController()
        controller.completion = completion

        let view = UntilTimePickerView(
            onConfirm: { date in
                controller.window?.close()
                completion(date)
            },
            onCancel: {
                controller.window?.close()
                completion(nil)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Meth — Until Time"
        window.contentView = NSHostingView(rootView: view)
        window.level = .floating
        controller.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

