import SwiftUI
import AppKit
import ServiceManagement
import MethCore

public struct SettingsView: View {
    @ObservedObject var sessionManager = SessionManager.shared
    @State private var launchAtLogin: Bool = false
    @State private var supportStatus: ClosedLidSupportStatus = .notInstalled
    @State private var actionMessage: String?
    @State private var isProcessing: Bool = false

    public init() {}

    private var isClosedLidSessionActive: Bool {
        sessionManager.activeSession?.closedLidMode ?? false
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        updateLaunchAtLogin(newValue)
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
                        .disabled(isProcessing)
                    }
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
            checkLaunchAtLoginStatus()
            checkSupportStatus()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch supportStatus {
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

    private func checkLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(_ enable: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                actionMessage = "Couldn't update Launch at Login: \(error.localizedDescription)"
            }
            // Always resync with the real system state rather than trusting the toggle's
            // optimistic value, so the UI never claims a registration that didn't happen.
            checkLaunchAtLoginStatus()
        }
    }

    private func checkSupportStatus() {
        Task {
            let status = await sessionManager.closedLidSupportStatus()
            await MainActor.run {
                self.supportStatus = status
            }
        }
    }

    private func installSupport() {
        isProcessing = true
        actionMessage = "Authenticating with macOS..."
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
                await MainActor.run {
                    self.isProcessing = false
                    self.actionMessage = error.localizedDescription
                }
            }
        }
    }

    private func uninstallSupport() {
        isProcessing = true
        actionMessage = "Authenticating with macOS..."
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
                await MainActor.run {
                    self.isProcessing = false
                    self.actionMessage = error.localizedDescription
                }
            }
        }
    }
}
