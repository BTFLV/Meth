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

    /// Added to the session's remaining time when arming the standalone watchdog so normal
    /// session expiration in `SessionManager` always finishes and stops the watchdog before
    /// the watchdog's own fallback timer fires.
    public static let watchdogTimeoutGracePeriodSeconds = 60

    private let privilegedService: any ClosedLidPrivilegedManaging
    private let lidMonitor: any LidStateMonitoring
    private let powerMonitor: any PowerSourceMonitoring
    private let thermalMonitor: any ThermalStateMonitoring
    private let watchdogClient: WatchdogClient

    private var state: State = .inactive
    private var lowBatteryThreshold: Int = PowerSourceState.lowBatteryThreshold

    /// Invoked when a low-battery safety cutoff stops an active session, with whether normal
    /// sleep behavior was actually restored. Fire-and-forget by design; the receiver is
    /// expected to hop back to its own isolation if needed.
    private var onLowBatteryCutoff: (@Sendable (_ threshold: Int, _ sleepRestored: Bool) -> Void)?

    /// Invoked when critical thermal pressure stops an active Closed-Lid session.
    private var onThermalCutoff: (@Sendable (_ sleepRestored: Bool) -> Void)?

    /// Invoked when the physical lid state changes while Closed-Lid Mode is active.
    private var onLidStateChange: (@Sendable (_ state: LidState) -> Void)?

    /// Invoked when Closed-Lid Mode can no longer guarantee protection while a session is
    /// still nominally active (for example, support was removed or reassertion failed
    /// repeatedly). The controller deactivates itself before calling this so the caller
    /// never has to reconcile "active" state with a mechanism that has already failed; the
    /// second argument reports whether normal sleep behavior was restored.
    private var onIntegrityFailure: (@Sendable (_ reason: String, _ sleepRestored: Bool) -> Void)?

    public init(
        privilegedService: any ClosedLidPrivilegedManaging = ClosedLidPrivilegedService.shared,
        lidMonitor: any LidStateMonitoring = LidStateMonitor(),
        powerMonitor: any PowerSourceMonitoring = PowerSourceMonitor(),
        thermalMonitor: any ThermalStateMonitoring = ThermalStateMonitor(),
        watchdogClient: WatchdogClient = WatchdogClient()
    ) {
        self.privilegedService = privilegedService
        self.lidMonitor = lidMonitor
        self.powerMonitor = powerMonitor
        self.thermalMonitor = thermalMonitor
        self.watchdogClient = watchdogClient

        lidMonitor.onLidStateChange = { [weak self] state in
            guard let self else { return }
            Task { await self.handleLidStateChange(state) }
        }
        powerMonitor.onPowerSourceChange = { [weak self] state in
            guard let self else { return }
            Task { await self.handlePowerSourceChange(state) }
        }
        thermalMonitor.onThermalStateChange = { [weak self] severity in
            guard let self else { return }
            Task { await self.handleThermalStateChange(severity) }
        }
    }

    deinit {
        watchdogClient.stop()
        lidMonitor.stopMonitoring()
        powerMonitor.stopMonitoring()
        thermalMonitor.stopMonitoring()
    }

    public var currentState: State {
        state
    }

    public var isClosedLidActive: Bool {
        state == .active
    }

    public var currentLidState: LidState {
        lidMonitor.currentState
    }

    public func supportStatus() -> ClosedLidSupportStatus {
        privilegedService.supportStatus()
    }

    public func setLowBatteryThreshold(_ threshold: Int) {
        lowBatteryThreshold = max(5, min(50, threshold))
        if state == .active {
            let power = powerMonitor.currentState
            if isBelowBatteryThreshold(power) {
                logger.warning("Battery is at or below updated threshold (\(self.lowBatteryThreshold)%). Triggering safety cutoff.")
                let usedThreshold = lowBatteryThreshold
                let restored = deactivate()
                onLowBatteryCutoff?(usedThreshold, restored)
            }
        }
    }

    public func setLowBatteryCutoffHandler(_ handler: @escaping @Sendable (_ threshold: Int, _ sleepRestored: Bool) -> Void) {
        onLowBatteryCutoff = handler
    }

    public func setThermalCutoffHandler(_ handler: @escaping @Sendable (_ sleepRestored: Bool) -> Void) {
        onThermalCutoff = handler
    }

    public func setLidStateChangeHandler(_ handler: @escaping @Sendable (_ state: LidState) -> Void) {
        onLidStateChange = handler
    }

    public func setIntegrityFailureHandler(_ handler: @escaping @Sendable (_ reason: String, _ sleepRestored: Bool) -> Void) {
        onIntegrityFailure = handler
    }

    private func isBelowBatteryThreshold(_ power: PowerSourceState) -> Bool {
        guard !power.hasExternalPower else { return false }
        if let level = power.batteryLevel {
            return level <= lowBatteryThreshold
        }
        return power.isLowBattery
    }

    private static func watchdogTimeout(for sessionTimeoutSeconds: Int?) -> Int? {
        guard let seconds = sessionTimeoutSeconds, seconds > 0 else { return nil }
        return seconds + watchdogTimeoutGracePeriodSeconds
    }

    /// Activates Closed-Lid Mode. Throws (without mutating any state) if support is not
    /// installed or the privileged mutation fails, so callers never observe a session that
    /// claims Closed-Lid protection when the underlying mechanism did not actually engage.
    public func activate(timeoutSeconds: Int? = nil) throws {
        let effectiveWatchdogTimeout = Self.watchdogTimeout(for: timeoutSeconds)
        switch state {
        case .active, .activating:
            watchdogClient.start(timeoutSeconds: effectiveWatchdogTimeout)
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
        guard !isBelowBatteryThreshold(power) else {
            state = .inactive
            throw ClosedLidError.batteryTooLow(power.batteryLevel)
        }

        // Refuse to start Closed-Lid Mode while the Mac is already in a critical thermal state.
        let thermal = thermalMonitor.currentState
        guard !thermal.isOverheated else {
            state = .inactive
            throw ClosedLidError.thermalPressureCritical
        }

        // Arm the watchdog before mutating SleepDisabled: if Meth crashes in the narrow
        // window right after enabling sleep, the watchdog is already watching and can
        // still recover, instead of depending solely on the next app launch.
        watchdogClient.start(timeoutSeconds: effectiveWatchdogTimeout)

        do {
            try privilegedService.enableSleepDisabled()
        } catch {
            watchdogClient.stop()
            state = .inactive
            throw error
        }

        lidMonitor.startMonitoring()
        powerMonitor.startMonitoring()
        thermalMonitor.startMonitoring()
        state = .active

        // If the lid is already closed when Closed-Lid Mode is enabled (for example via SSH,
        // Shortcuts, or just before unplugging an external display), put the internal display
        // to sleep right away rather than waiting for a future lid-close transition.
        if lidMonitor.currentState == .closed {
            privilegedService.putDisplayToSleep()
        }

        logger.info("Closed-Lid Mode successfully activated.")
    }

    /// Re-arms the watchdog with a new time limit after the session was extended. Does
    /// nothing unless Closed-Lid Mode is currently active: an extension must never (re-)enable
    /// it, for example when it races with the session being stopped.
    public func updateWatchdogTimeout(_ timeoutSeconds: Int?) {
        guard state == .active else { return }
        watchdogClient.start(timeoutSeconds: Self.watchdogTimeout(for: timeoutSeconds))
    }

    /// - Returns: `true` if normal sleep behavior is known to be restored (including when
    ///   Closed-Lid Mode was not active to begin with). `false` means the Mac may still be
    ///   unable to sleep; the watchdog is deliberately left running in that case, and callers
    ///   should tell the user rather than reporting a clean stop.
    @discardableResult
    public func deactivate() -> Bool {
        guard state == .active || state == .activating else { return true }
        state = .deactivating

        lidMonitor.stopMonitoring()
        powerMonitor.stopMonitoring()
        thermalMonitor.stopMonitoring()

        let restored = revertSleepDisabled()
        state = .inactive
        return restored
    }

    private func revertSleepDisabled() -> Bool {
        do {
            try privilegedService.disableSleepDisabled()
            logger.info("Closed-Lid Mode deactivated and SleepDisabled reverted.")
        } catch {
            logger.error("Error reverting SleepDisabled: \(error.localizedDescription)")
            // What matters is the resulting state, not the command: macOS may already have
            // cleared the flag, e.g. after support was removed and powerd reset it.
            guard !privilegedService.isSleepDisabled() else {
                // The watchdog stays running as a safety net rather than removing the one
                // thing that might still recover the Mac later.
                return false
            }
            privilegedService.clearOwnershipMarker()
        }
        watchdogClient.stop()
        return true
    }

    /// Launch-time recovery for a `SleepDisabled` state left over from an ungraceful exit.
    /// Only acts on state Meth believes it owns (see
    /// `ClosedLidPrivilegedManaging.isOwnershipMarkerSet`), so a value left by another tool
    /// or an administrator is never clobbered. Runs on this actor so it can never interleave
    /// with an activation and revert a session that has just been started.
    public func performStartupRecovery() {
        guard state == .inactive else { return }
        guard privilegedService.isOwnershipMarkerSet() else {
            if privilegedService.isSleepDisabled() {
                logger.notice("SleepDisabled is currently enabled but not owned by Meth; leaving system state untouched.")
            }
            return
        }
        if privilegedService.isSleepDisabled() {
            logger.warning("Startup recovery: reverting Meth-owned SleepDisabled state left over from a previous session.")
            privilegedService.restoreSleepDisabledForFailsafe(maxAttempts: 3)
        } else {
            privilegedService.clearOwnershipMarker()
        }
    }

    /// Whether system sleep is disabled even though no Closed-Lid session is active here:
    /// a revert that failed, a leftover Meth could not recover, or another tool's setting.
    public func isSleepDisabledOutsideSession() -> Bool {
        state == .inactive && privilegedService.isSleepDisabled()
    }

    /// Turns `SleepDisabled` off at the user's explicit request, whoever set it. Uses the
    /// installed rule when it works; otherwise macOS asks for administrator authentication
    /// once to run the same fixed `pmset` command. Refused while a Closed-Lid session is
    /// active, which should be stopped instead.
    public func restoreNormalSleep() throws {
        guard state == .inactive else {
            throw ClosedLidError.activeSessionInProgress
        }
        guard privilegedService.isSleepDisabled() else { return }

        if privilegedService.supportStatus() == .installed,
           privilegedService.restoreSleepDisabledForFailsafe(maxAttempts: 2) {
            watchdogClient.stop()
            return
        }
        try privilegedService.restoreSleepDisabledWithAdministratorPrivileges()
        watchdogClient.stop()
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
        onLidStateChange?(newState)
        if newState == .closed {
            // Put the internal display to sleep immediately: it has no reason to stay lit
            // once the lid is shut, and doing so avoids wasted power and backlight heat.
            privilegedService.putDisplayToSleep()
        }
    }

    private func handleThermalStateChange(_ severity: ThermalSeverity) {
        guard state == .active else { return }

        logger.info("Handling thermal state transition: \(String(describing: severity))")
        if severity.isOverheated {
            logger.warning("Critical thermal pressure detected while in Closed-Lid Mode. Triggering thermal safety cutoff.")
            let restored = deactivate()
            onThermalCutoff?(restored)
        }
    }

    private func handlePowerSourceChange(_ newState: PowerSourceState) {
        guard state == .active else { return }

        logger.info("Handling power source transition: AC=\(newState.hasExternalPower), Battery=\(String(describing: newState.batteryLevel))%, Low=\(newState.isLowBattery)")

        if isBelowBatteryThreshold(newState) {
            let usedThreshold = lowBatteryThreshold
            logger.warning("Battery reached low threshold (\(usedThreshold)%) while in Closed-Lid Mode. Triggering safety cutoff.")
            let restored = deactivate()
            onLowBatteryCutoff?(usedThreshold, restored)
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
                let restored = deactivate()
                onIntegrityFailure?(reason, restored)
            }
        }
    }
}
