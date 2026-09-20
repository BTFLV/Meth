import SwiftUI
import AppKit
import ServiceManagement
import MethCore

public struct SettingsView: View {
    @ObservedObject var sessionManager = SessionManager.shared
    @State private var launchAtLogin: Bool = false
    @State private var isSupportInstalled: Bool = ClosedLidPrivilegedService.shared.isSupportInstalled
    @State private var actionMessage: String?
    @State private var isProcessing: Bool = false

    public init() {}

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
                    if isSupportInstalled {
                        Text("Installed")
                            .font(.callout.bold())
                            .foregroundColor(.green)
                    } else {
                        Text("Not Installed")
                            .font(.callout.bold())
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isSupportInstalled {
                        Button("Remove Support") {
                            uninstallSupport()
                        }
                        .disabled(isProcessing)
                    } else {
                        Button("Install Support") {
                            installSupport()
                        }
                        .disabled(isProcessing)
                    }
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
        .frame(width: 480, height: 380)
        .onAppear {
            checkLaunchAtLoginStatus()
            checkSupportStatus()
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
                actionMessage = "Failed to update Launch at Login: \(error.localizedDescription)"
            }
        }
    }

    private func checkSupportStatus() {
        isSupportInstalled = ClosedLidPrivilegedService.shared.isSupportInstalled
    }

    private func installSupport() {
        isProcessing = true
        actionMessage = "Authenticating with macOS..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ClosedLidPrivilegedService.shared.installSupport()
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.isSupportInstalled = true
                    self.actionMessage = "Closed-Lid support installed successfully."
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.actionMessage = error.localizedDescription
                }
            }
        }
    }

    private func uninstallSupport() {
        isProcessing = true
        actionMessage = "Authenticating with macOS..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ClosedLidPrivilegedService.shared.uninstallSupport()
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.isSupportInstalled = false
                    self.actionMessage = "Closed-Lid support removed successfully."
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.actionMessage = error.localizedDescription
                }
            }
        }
    }
}

public final class SettingsWindowController: NSWindowController {
    private static var instance: SettingsWindowController?

    public static func show() {
        if let existing = instance {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Meth Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        controller.window = window
        instance = controller

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

