import AppKit
import Combine
import MethCore

@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let sessionManager: SessionManager
    private var cancellables = Set<AnyCancellable>()

    public init(sessionManager: SessionManager? = nil) {
        self.sessionManager = sessionManager ?? SessionManager.shared
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        setupStatusItem()
        observeSession()
        updateIcon()
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        updateIcon()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func observeSession() {
        sessionManager.$activeSession
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        sessionManager.$remainingTime
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateRemainingTimeItem()
            }
            .store(in: &cancellables)

        sessionManager.$lastAutomaticStopReason
            .receive(on: RunLoop.main)
            .compactMap { $0 }
            .sink { [weak self] reason in
                self?.presentAutomaticStopAlert(reason: reason)
            }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let isActive = sessionManager.isSessionActive
        let isClosedLid = sessionManager.activeSession?.closedLidMode ?? false
        statusItem.button?.image = MenuBarIcon.image(isActive: isActive, isClosedLid: isClosedLid)
    }

    public func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        if let session = sessionManager.activeSession {
            buildActiveMenu(menu, session: session)
        } else {
            buildInactiveMenu(menu)
        }

        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit Meth", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func buildActiveMenu(_ menu: NSMenu, session: Session) {
        let header = NSMenuItem(title: "Meth — Active", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let remaining = sessionManager.remainingTime {
            let remItem = NSMenuItem(
                title: "Remaining: \(SessionDuration.formatRemaining(seconds: remaining))",
                action: nil,
                keyEquivalent: ""
            )
            remItem.tag = 1001
            remItem.isEnabled = false
            menu.addItem(remItem)
        }

        if session.closedLidMode {
            let clItem = NSMenuItem(title: "Closed-Lid Mode: Enabled", action: nil, keyEquivalent: "")
            clItem.isEnabled = false
            menu.addItem(clItem)
        }

        menu.addItem(NSMenuItem.separator())

        let stopItem = NSMenuItem(title: "Stop Session", action: #selector(stopSession), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        if !session.duration.isIndefinite {
            let extendMenu = NSMenu()
            let add15 = NSMenuItem(title: "+15 Minutes", action: #selector(extend15Min), keyEquivalent: "")
            add15.target = self
            extendMenu.addItem(add15)

            let add60 = NSMenuItem(title: "+1 Hour", action: #selector(extend60Min), keyEquivalent: "")
            add60.target = self
            extendMenu.addItem(add60)

            let extendItem = NSMenuItem(title: "Extend", action: nil, keyEquivalent: "")
            extendItem.submenu = extendMenu
            menu.addItem(extendItem)
        }
    }

    private func buildInactiveMenu(_ menu: NSMenu) {
        let header = NSMenuItem(title: "Meth", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())

        let startItem = NSMenuItem(title: "Start Session", action: nil, keyEquivalent: "")
        let startMenu = NSMenu()

        addDurationItem(to: startMenu, title: "Indefinitely", duration: .indefinite)
        addDurationItem(to: startMenu, title: "5 Minutes", duration: .preset(SessionDuration.fiveMinutes))
        addDurationItem(to: startMenu, title: "15 Minutes", duration: .preset(SessionDuration.fifteenMinutes))
        addDurationItem(to: startMenu, title: "30 Minutes", duration: .preset(SessionDuration.thirtyMinutes))
        addDurationItem(to: startMenu, title: "1 Hour", duration: .preset(SessionDuration.oneHour))
        addDurationItem(to: startMenu, title: "2 Hours", duration: .preset(SessionDuration.twoHours))
        addDurationItem(to: startMenu, title: "4 Hours", duration: .preset(SessionDuration.fourHours))
        addDurationItem(to: startMenu, title: "8 Hours", duration: .preset(SessionDuration.eightHours))

        let untilItem = NSMenuItem(title: "Until...", action: #selector(startUntilTimeSession), keyEquivalent: "")
        untilItem.target = self
        startMenu.addItem(untilItem)

        startItem.submenu = startMenu
        menu.addItem(startItem)

        menu.addItem(NSMenuItem.separator())

        let optionsHeader = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsHeader.isEnabled = false
        menu.addItem(optionsHeader)

        let displaySleepItem = NSMenuItem(
            title: "Allow Display Sleep",
            action: #selector(toggleDisplaySleep),
            keyEquivalent: ""
        )
        displaySleepItem.target = self
        displaySleepItem.state = sessionManager.defaultAllowDisplaySleep ? .on : .off
        menu.addItem(displaySleepItem)

        let closedLidItem = NSMenuItem(
            title: "Closed-Lid Mode",
            action: #selector(toggleClosedLid),
            keyEquivalent: ""
        )
        closedLidItem.target = self
        closedLidItem.state = sessionManager.defaultClosedLidMode ? .on : .off
        menu.addItem(closedLidItem)
    }

    private func addDurationItem(to menu: NSMenu, title: String, duration: SessionDuration) {
        let item = NSMenuItem(title: title, action: #selector(startSessionPreset(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = duration
        menu.addItem(item)
    }

    private func updateRemainingTimeItem() {
        guard let item = statusItem.menu?.item(withTag: 1001),
              let remaining = sessionManager.remainingTime else { return }
        item.title = "Remaining: \(SessionDuration.formatRemaining(seconds: remaining))"
    }

    @objc private func startSessionPreset(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? SessionDuration else { return }
        startSessionWithCurrentOptions(duration: duration)
    }

    @objc private func startUntilTimeSession() {
        UntilTimeWindowController.show { [weak self] targetDate in
            guard let self = self, let date = targetDate else { return }
            self.startSessionWithCurrentOptions(duration: .until(date))
        }
    }

    private func startSessionWithCurrentOptions(duration: SessionDuration) {
        // If Closed-Lid Mode is requested, check thermal warning acknowledgement and support status
        if sessionManager.defaultClosedLidMode {
            if !sessionManager.hasAcknowledgedThermalWarning {
                ThermalWarningWindowController.show(
                    onConfirm: { [weak self] in
                        guard let self = self else { return }
                        self.sessionManager.hasAcknowledgedThermalWarning = true
                        self.proceedWithStart(duration: duration)
                    },
                    onCancel: {}
                )
                return
            }
        }
        proceedWithStart(duration: duration)
    }

    private func proceedWithStart(duration: SessionDuration) {
        Task { @MainActor in
            do {
                try await sessionManager.startSession(duration: duration)
            } catch ClosedLidError.supportNotInstalled {
                showSupportRequiredAlert()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to start session"
                alert.informativeText = errorSummary(for: error)
                runAlert(alert)
            }
        }
    }

    /// Standardizes what a failure explains to the user: what failed, whether the Mac is
    /// still protected, and what to do next -- without exposing raw shell command text.
    private func errorSummary(for error: Error) -> String {
        switch error {
        case let closedLidError as ClosedLidError:
            switch closedLidError {
            case .batteryTooLow:
                // Self-explanatory and actionable on its own; the generic "reinstall
                // support" advice below would be actively misleading here.
                return closedLidError.localizedDescription
            default:
                return "Closed-Lid Mode could not be enabled. Normal keep-awake protection was not started, so no partially active session was left running.\n\nReinstall Closed-Lid Support in Settings and try again."
            }
        default:
            return error.localizedDescription
        }
    }

    private func showSupportRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = "Closed-Lid Support Required"
        alert.informativeText = "Closed-Lid Mode requires installing privileged support in Settings. Would you like to open Settings now?"
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if runAlert(alert) == .alertFirstButtonReturn {
            openSettings()
        }
    }

    private func presentAutomaticStopAlert(reason: String) {
        sessionManager.clearLastAutomaticStopReason()
        let alert = NSAlert()
        alert.messageText = "Session Stopped Automatically"
        alert.informativeText = reason
        runAlert(alert)
    }

    /// An `LSUIElement` app is never the frontmost application on its own, so a modal
    /// alert would otherwise open behind whatever the user is working in -- blocking Meth
    /// on a dialog they cannot see.
    @discardableResult
    private func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    @objc private func stopSession() {
        Task { @MainActor in
            await sessionManager.stopSession()
        }
    }

    @objc private func extend15Min() {
        Task { @MainActor in
            await sessionManager.extendSession(by: SessionDuration.fifteenMinutes)
        }
    }

    @objc private func extend60Min() {
        Task { @MainActor in
            await sessionManager.extendSession(by: SessionDuration.oneHour)
        }
    }

    @objc private func toggleDisplaySleep() {
        sessionManager.defaultAllowDisplaySleep.toggle()
        rebuildMenu()
    }

    @objc private func toggleClosedLid() {
        let newState = !sessionManager.defaultClosedLidMode
        if newState && !sessionManager.hasAcknowledgedThermalWarning {
            ThermalWarningWindowController.show(
                onConfirm: { [weak self] in
                    guard let self = self else { return }
                    self.sessionManager.hasAcknowledgedThermalWarning = true
                    self.sessionManager.defaultClosedLidMode = true
                    self.rebuildMenu()
                },
                onCancel: {}
            )
        } else {
            sessionManager.defaultClosedLidMode = newState
            rebuildMenu()
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.show()
    }

    @objc private func quitApp() {
        // Cleanup happens in `applicationShouldTerminate`, which defers termination until
        // the async session teardown actually completes.
        NSApp.terminate(nil)
    }
}
