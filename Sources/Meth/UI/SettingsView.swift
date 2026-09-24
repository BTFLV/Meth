import SwiftUI
import AppKit
import ServiceManagement
import MethCore

public struct SettingsView: View {
    @ObservedObject var sessionManager = SessionManager.shared
    @State private var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    @State private var loginItemMessage: String?
    /// `nil` until the first status check has finished.
    @State private var supportStatus: ClosedLidSupportStatus?
    @State private var actionMessage: String?
    @State private var isProcessing: Bool = false

    public init() {}

    private var isClosedLidSessionActive: Bool {
        sessionManager.activeSession?.closedLidMode ?? false
    }

    /// On while Meth is registered as a login item, including while macOS still needs the
    /// user's approval for it in System Settings.
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
            set: { updateLaunchAtLogin($0) }
        )
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: launchAtLogin)

                if loginItemStatus == .requiresApproval {
                    HStack {
                        Text("macOS is blocking Meth from opening at login. Allow it in System Settings → General → Login Items.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Open Login Items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }

                if let message = loginItemMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Allow Display Sleep by default", isOn: $sessionManager.defaultAllowDisplaySleep)

                Toggle("Enable Closed-Lid Mode by default", isOn: $sessionManager.defaultClosedLidMode)
                    .onChange(of: sessionManager.defaultClosedLidMode) { newValue in
                        if newValue && !sessionManager.hasAcknowledgedThermalWarning {
                            ThermalWarningWindowController.show(
                                onConfirm: {
                                    sessionManager.hasAcknowledgedThermalWarning = true
                                },
                                onCancel: {
                                    sessionManager.defaultClosedLidMode = false
                                }
                            )
                        }
                    }
            }

            Section("Closed-Lid Support") {
                HStack {
                    Text("Status:")
                    statusLabel
                    Spacer()
                    if case .installed = supportStatus {
                        Button("Remove Support") {
                            uninstallSupport()
                        }
                        .disabled(isProcessing || isClosedLidSessionActive)
                    } else {
                        Button("Install Support") {
                            installSupport()
                        }
                        .disabled(isProcessing || supportStatus == nil)
                    }
                }

                if case .invalidConfiguration(let reason) = supportStatus {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if isClosedLidSessionActive {
                    Text("Stop the active Closed-Lid session before removing support.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let message = actionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("Closed-Lid Mode prevents sleep when the MacBook lid is closed. To function without prompting for a password each time, Meth configures a strictly scoped rule in /private/etc/sudoers.d/meth-closed-lid that allows only '/usr/bin/pmset -a disablesleep'.\n\nNo background daemons, network access, or arbitrary root commands are allowed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 400)
        .onAppear {
            refreshStatus()
        }
        // Either status may have been changed outside Meth (e.g. in System Settings) while
        // this window stayed open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch supportStatus {
        case nil:
            Text("Checking…")
                .font(.callout)
                .foregroundColor(.secondary)
        case .installed:
            Text("Installed")
                .font(.callout.bold())
                .foregroundColor(.green)
        case .notInstalled:
            Text("Not Installed")
                .font(.callout.bold())
                .foregroundColor(.secondary)
        case .invalidConfiguration:
            Text("Needs Attention")
                .font(.callout.bold())
                .foregroundColor(.orange)
        }
    }

    private func updateLaunchAtLogin(_ enable: Bool) {
        loginItemMessage = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemMessage = "Couldn't update Launch at Login: \(error.localizedDescription)"
        }
        // Always resync with the real system state rather than trusting the toggle's
        // optimistic value, so the UI never claims a registration that didn't happen.
        loginItemStatus = SMAppService.mainApp.status
    }

    private func refreshStatus() {
        loginItemStatus = SMAppService.mainApp.status
        Task {
            let status = await sessionManager.closedLidSupportStatus()
            await MainActor.run {
                self.supportStatus = status
            }
        }
    }

    private func installSupport() {
        isProcessing = true
        actionMessage = "Authenticating with macOS…"
        Task {
            do {
                try await sessionManager.installClosedLidSupport()
                let status = await sessionManager.closedLidSupportStatus()
                await MainActor.run {
                    self.isProcessing = false
                    self.supportStatus = status
                    self.actionMessage = "Closed-Lid support installed successfully."
                }
            } catch {
                await finishFailedAction(error)
            }
        }
    }

    private func uninstallSupport() {
        isProcessing = true
        actionMessage = "Authenticating with macOS…"
        Task {
            do {
                try await sessionManager.uninstallClosedLidSupport()
                let status = await sessionManager.closedLidSupportStatus()
                await MainActor.run {
                    self.isProcessing = false
                    self.supportStatus = status
                    self.actionMessage = "Closed-Lid support removed successfully."
                }
            } catch {
                await finishFailedAction(error)
            }
        }
    }

    private func finishFailedAction(_ error: Error) async {
        // Validation after a failed or partial attempt may have changed the status too.
        let status = await sessionManager.closedLidSupportStatus()
        await MainActor.run {
            self.isProcessing = false
            self.supportStatus = status
            // Dismissing the authentication prompt is a choice, not an error.
            self.actionMessage = (error as? ClosedLidError) == .authorizationCancelled ? nil : error.localizedDescription
        }
    }
}
