import Foundation
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "ClosedLidController")

/// Owns the Closed-Lid Mode lifecycle: the privileged `SleepDisabled` mechanism, lid/power
/// monitoring, and the crash-recovery watchdog.
///
/// This type is an `actor` rather than a lock-guarded class so that:
/// - activation and deactivation are mutually exclusive by construction (no explicit
///   locking is needed, and there is no way for two privileged mutations to overlap);
/// - the blocking `Process`/AppleScript calls made by `ClosedLidPrivilegedManaging` run on
///   the actor's own executor, off the caller's (typically `@MainActor`) thread, without
///   any manual `DispatchQueue` juggling.
public actor ClosedLidController {
    public enum State: Equatable, Sendable {
        case inactive
        case activating
        case active
        case deactivating
    }

    private let privilegedService: any ClosedLidPrivilegedManaging
    private let lidMonitor: any LidStateMonitoring
    private let powerMonitor: any PowerSourceMonitoring
    private let watchdogClient: WatchdogClient

    private var state: State = .inactive

    /// Invoked when a low-battery safety cutoff stops an active session. Fire-and-forget
    /// by design; the receiver is expected to hop back to its own isolation if needed.
    private var onLowBatteryCutoff: (@Sendable () -> Void)?

    /// Invoked when Closed-Lid Mode can no longer guarantee protection while a session is
    /// still nominally active (for example, support was removed or reassertion failed
    /// repeatedly). The controller deactivates itself before calling this so the caller
    /// never has to reconcile "active" state with a mechanism that has already failed.
    private var onIntegrityFailure: (@Sendable (String) -> Void)?

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

        lidMonitor.onLidStateChange = { [weak self] state in
            guard let self else { return }
            Task { await self.handleLidStateChange(state) }
        }
        powerMonitor.onPowerSourceChange = { [weak self] state in
            guard let self else { return }
            Task { await self.handlePowerSourceChange(state) }
        }
    }

    deinit {
        watchdogClient.stop()
        lidMonitor.stopMonitoring()
        powerMonitor.stopMonitoring()
    }

    public var currentState: State {
        state
    }

    public var isClosedLidActive: Bool {
        state == .active
    }

    public func supportStatus() -> ClosedLidSupportStatus {
        privilegedService.supportStatus()
    }

    public func setLowBatteryCutoffHandler(_ handler: @escaping @Sendable () -> Void) {
        onLowBatteryCutoff = handler
    }

    public func setIntegrityFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        onIntegrityFailure = handler
    }

    /// Activates Closed-Lid Mode. Throws (without mutating any state) if support is not
    /// installed or the privileged mutation fails, so callers never observe a session that
    /// claims Closed-Lid protection when the underlying mechanism did not actually engage.
    public func activate(timeoutSeconds: Int? = nil) throws {
        switch state {
        case .active, .activating:
            watchdogClient.start(timeoutSeconds: timeoutSeconds)
            return
        case .deactivating:
            throw ClosedLidError.activeSessionInProgress
        case .inactive:
            break
        }

        state = .activating

        // Check support up front so the common "not installed" failure never spawns and
        // immediately kills a watchdog process for nothing.
        guard privilegedService.supportStatus() == .installed else {
            state = .inactive
            throw ClosedLidError.supportNotInstalled
        }

        // The low-battery cutoff below only reacts to power source *changes*. Without this
        // check, starting a Closed-Lid session while already below the threshold would run
        // unprotected until the battery happened to change again -- exactly the situation
        // the cutoff exists to prevent.
        let power = powerMonitor.currentState
        guard !power.isLowBattery else {
            state = .inactive
            throw ClosedLidError.batteryTooLow(power.batteryLevel)
        }

        // Arm the watchdog before mutating SleepDisabled: if Meth crashes in the narrow
        // window right after enabling sleep, the watchdog is already watching and can
        // still recover, instead of depending solely on the next app launch.
        watchdogClient.start(timeoutSeconds: timeoutSeconds)

        do {
            try privilegedService.enableSleepDisabled()
        } catch {
            watchdogClient.stop()
            state = .inactive
            throw error
        }

        lidMonitor.startMonitoring()
        powerMonitor.startMonitoring()
        state = .active
        logger.info("Closed-Lid Mode successfully activated.")
    }

    /// - Returns: `true` if normal sleep behavior is known to be restored (including when
    ///   Closed-Lid Mode was not active to begin with). `false` means the privileged revert
    ///   failed and the Mac may still be unable to sleep; the watchdog is deliberately left
    ///   running in that case, and callers should tell the user rather than reporting a
    ///   clean stop.
    @discardableResult
    public func deactivate() -> Bool {
        guard state == .active || state == .activating else { return true }
        state = .deactivating

        lidMonitor.stopMonitoring()
        powerMonitor.stopMonitoring()

        var restored = false
        do {
            try privilegedService.disableSleepDisabled()
            logger.info("Closed-Lid Mode deactivated and SleepDisabled reverted.")
            // Only torn down once restoration actually succeeded: if it failed, the
            // watchdog is left running as a continued safety net rather than removing the
            // one thing that might still recover the Mac later.
            watchdogClient.stop()
            restored = true
        } catch {
            logger.error("Error reverting SleepDisabled: \(error.localizedDescription)")
        }
        state = .inactive
        return restored
    }

    /// Removing privileged support must never be allowed to happen underneath an active
    /// session, or the UI would keep claiming protection that no longer exists.
    public func uninstallSupport() throws {
        guard state == .inactive else {
            throw ClosedLidError.activeSessionInProgress
        }
        try privilegedService.uninstallSupport()
    }

    public func installSupport() throws {
        try privilegedService.installSupport()
    }

    private func handleLidStateChange(_ newState: LidState) {
        guard state == .active else { return }

        logger.info("Handling lid state transition: \(newState.rawValue)")
        if newState == .closed {
            // Put the internal display to sleep immediately: it has no reason to stay lit
            // once the lid is shut, and doing so avoids wasted power and backlight heat.
            privilegedService.putDisplayToSleep()
        }
    }

    private func handlePowerSourceChange(_ newState: PowerSourceState) {
        guard state == .active else { return }

        logger.info("Handling power source transition: AC=\(newState.hasExternalPower), Battery=\(String(describing: newState.batteryLevel))%, Low=\(newState.isLowBattery)")

        if newState.isLowBattery {
            logger.warning("Battery reached low threshold while in Closed-Lid Mode. Triggering safety cutoff.")
            deactivate()
            onLowBatteryCutoff?()
            return
        }

        // Apple Silicon's powerd can clear SleepDisabled across certain power source
        // transitions; re-assert it while we are definitively still active.
        guard !privilegedService.isSleepDisabled() else { return }

        logger.info("Re-asserting SleepDisabled across power source transition.")
        do {
            try privilegedService.enableSleepDisabled()
        } catch {
            logger.error("Failed to re-assert SleepDisabled after power source change: \(error.localizedDescription)")
            if privilegedService.supportStatus() != .installed {
                // Support disappeared out from under an active session: fail safe instead
                // of silently continuing to claim Closed-Lid protection.
                let reason = "Closed-Lid support became unavailable while a session was active."
                deactivate()
                onIntegrityFailure?(reason)
            }
        }
    }
}
