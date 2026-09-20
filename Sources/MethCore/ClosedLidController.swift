import Foundation
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "ClosedLidController")

public final class ClosedLidController: @unchecked Sendable {
    private let lock = NSLock()
    private let privilegedService: any ClosedLidPrivilegedManaging
    private let lidMonitor: any LidStateMonitoring
    private let powerMonitor: any PowerSourceMonitoring
    private let watchdogClient: WatchdogClient

    private var isActive = false
    public var onLowBatteryCutoff: (@Sendable () -> Void)?

    public init(
        privilegedService: any ClosedLidPrivilegedManaging = ClosedLidPrivilegedService.shared,
        lidMonitor: any LidStateMonitoring = LidStateMonitor(),
        powerMonitor: any PowerSourceMonitoring = PowerSourceMonitor(),
        watchdogClient: WatchdogClient = WatchdogClient()
    ) {
        self.privilegedService = privilegedService
        self.lidMonitor = lidMonitor
        self.powerMonitor = powerMonitor
        self.watchdogClient = watchdogClient

        setupCallbacks()
    }

    deinit {
        deactivate()
    }

    public var isClosedLidActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    public func activate(timeoutSeconds: Int? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isActive else {
            // Update watchdog timeout if already active
            watchdogClient.start(timeoutSeconds: timeoutSeconds)
            return
        }

        guard privilegedService.isSupportInstalled else {
            throw ClosedLidError.supportNotInstalled
        }

        try privilegedService.enableSleepDisabled()
        watchdogClient.start(timeoutSeconds: timeoutSeconds)
        lidMonitor.startMonitoring()
        powerMonitor.startMonitoring()
        isActive = true
        logger.info("Closed-Lid Mode successfully activated.")
    }

    public func deactivate() {
        lock.lock()
        defer { lock.unlock() }

        guard isActive else { return }
        isActive = false

        watchdogClient.stop()
        lidMonitor.stopMonitoring()
        powerMonitor.stopMonitoring()

        do {
            try privilegedService.disableSleepDisabled()
            logger.info("Closed-Lid Mode deactivated and SleepDisabled reverted.")
        } catch {
            logger.error("Error reverting SleepDisabled: \(error.localizedDescription)")
        }
    }

    private func setupCallbacks() {
        lidMonitor.onLidStateChange = { [weak self] state in
            self?.handleLidStateChange(state)
        }

        powerMonitor.onPowerSourceChange = { [weak self] state in
            self?.handlePowerSourceChange(state)
        }
    }

    private func handleLidStateChange(_ state: LidState) {
        lock.lock()
        let active = isActive
        lock.unlock()

        guard active else { return }

        logger.info("Handling lid state transition: \(state.rawValue)")
        if state == .closed {
            // When lid closes, immediately put internal display to sleep to eliminate backlight heat and power
            privilegedService.putDisplayToSleep()
        }
    }

    private func handlePowerSourceChange(_ state: PowerSourceState) {
        lock.lock()
        let active = isActive
        lock.unlock()

        guard active else { return }

        logger.info("Handling power source transition: AC=\(state.hasExternalPower), Battery=\(String(describing: state.batteryLevel))%, Low=\(state.isLowBattery)")

        // Check for low battery cutoff
        if state.isLowBattery {
            logger.warning("Battery reached low threshold while in Closed-Lid Mode. Triggering safety cutoff.")
            deactivate()
            DispatchQueue.main.async { [weak self] in
                self?.onLowBatteryCutoff?()
            }
            return
        }

        // Handle Apple Silicon power transition: ensure SleepDisabled was not reset by kernel
        if !privilegedService.isSleepDisabled() {
            logger.info("Re-asserting SleepDisabled across power source transition.")
            try? privilegedService.enableSleepDisabled()
        }
    }
}

