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

            // A time that has already passed today means tomorrow; say which one it is.
            TimelineView(.everyMinute) { _ in
                Text("Ends \(SessionDuration.describeTime(resolvedEndDate()))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Start Session") {
                    onConfirm(resolvedEndDate())
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 280)
    }

    /// The next occurrence of the selected clock time: today if it is still ahead,
    /// otherwise tomorrow.
    private func resolvedEndDate() -> Date {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: selectedDate)
        let minute = calendar.component(.minute, from: selectedDate)
        return SessionDuration.nextDate(hour: hour, minute: minute)
    }
}

@MainActor
public enum UntilTimeWindowController {
    /// The completion is called exactly once — with `nil` if the user cancels or closes
    /// the window, and with the chosen date otherwise.
    public static func show(completion: @escaping (Date?) -> Void) {
        var hasAnswered = false

        AuxiliaryWindowController.present(
            title: "Meth — Until Time",
            size: NSSize(width: 280, height: 230),
            onCloseWithoutAction: {
                guard !hasAnswered else { return }
                hasAnswered = true
                completion(nil)
            }
        ) { dismiss in
            UntilTimePickerView(
                onConfirm: { date in
                    hasAnswered = true
                    dismiss()
                    completion(date)
                },
                onCancel: {
                    hasAnswered = true
                    dismiss()
                    completion(nil)
                }
            )
        }
    }
}

