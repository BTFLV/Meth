import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "SessionManager")

private extension Duration {
    var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}

@MainActor
public final class SessionManager: ObservableObject {
    public static let shared = SessionManager()

    /// A single, shared monotonic clock instance used for every `.preset` session deadline.
    private static let clock = ContinuousClock()

    /// Appended to every report of a Closed-Lid stop that could not restore normal sleep.
    static let sleepNotRestoredAdvice = "Normal sleep could not be restored, so your Mac may stay awake even with the lid closed. Choose Restore Normal Sleep from the Meth menu, or run \"sudo pmset -a disablesleep 0\" in Terminal."

    @Published public private(set) var activeSession: Session?
    @Published public private(set) var remainingTime: TimeInterval?
    /// Set when a session was stopped or downgraded automatically (low battery, integrity
    /// failure), or when stopping could not restore normal sleep. Cleared by the UI after
    /// being surfaced once.
    @Published public private(set) var lastAutomaticStopReason: String?
    /// `true` while system sleep is disabled although no Closed-Lid session is active in
    /// Meth: a revert that failed, a leftover Meth could not recover, or another tool's
    /// setting. Updated by `refreshSleepState()` rather than by polling.
    @Published public private(set) var isSleepDisabledOutsideSession = false
    @Published public var defaultAllowDisplaySleep: Bool {
        didSet {
            UserDefaults.standard.set(defaultAllowDisplaySleep, forKey: "defaultAllowDisplaySleep")
        }
    }
    @Published public var defaultClosedLidMode: Bool {
        didSet {
            UserDefaults.standard.set(defaultClosedLidMode, forKey: "defaultClosedLidMode")
        }
    }
    @Published public var hasAcknowledgedThermalWarning: Bool {
        didSet {
            UserDefaults.standard.set(hasAcknowledgedThermalWarning, forKey: "hasAcknowledgedThermalWarning")
        }
    }

    public var isSessionActive: Bool {
        activeSession != nil
    }

    /// When the active session ends, or `nil` if there is none or it has no time limit.
    public var sessionEndDate: Date? {
        guard let session = activeSession else { return nil }
        switch session.duration {
        case .indefinite:
            return nil
        case .until(let targetDate):
            return targetDate
        case .preset:
            return remainingTime.map { Date().addingTimeInterval($0) } ?? session.endDate
        }
    }

    private let powerAssertionManager: any PowerAssertionManaging
    let closedLidController: ClosedLidController
    private let privilegedService: any ClosedLidPrivilegedManaging

    private var systemSleepAssertion: AssertionToken?
    private var displaySleepAssertion: AssertionToken?

    /// The single authoritative mechanism that ends a session. The 1 Hz timer below only
    /// refreshes the displayed countdown; it never stops the session itself.
    private var expirationTask: Task<Void, Never>?
    private var displayRefreshTimer: Timer?
    /// Monotonic deadline backing `.preset` sessions, so a manual clock change or large NTP
    /// adjustment cannot cause premature or delayed expiration.
    private var monotonicDeadline: ContinuousClock.Instant?

    /// Session operations (start, stop, extend, restore) run strictly one after another.
    /// Each can suspend while Closed-Lid Mode is switched, and interleaving them could, for
    /// example, extend a session that is being stopped (re-enabling Closed-Lid Mode with no
    /// session left to turn it off) or let one start replace another without stopping it.
    private var lastOperation: Task<Void, Never>?
    private var sleepStateRefreshGeneration = 0

    public init(
        powerAssertionManager: any PowerAssertionManaging = PowerAssertionManager(),
        closedLidController: ClosedLidController = ClosedLidController(),
        privilegedService: any ClosedLidPrivilegedManaging = ClosedLidPrivilegedService.shared
    ) {
        self.powerAssertionManager = powerAssertionManager
        self.closedLidController = closedLidController
        self.privilegedService = privilegedService

        // Load preferences with sensible defaults
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "defaultAllowDisplaySleep") == nil {
            self.defaultAllowDisplaySleep = true
        } else {
            self.defaultAllowDisplaySleep = defaults.bool(forKey: "defaultAllowDisplaySleep")
        }

        self.defaultClosedLidMode = defaults.bool(forKey: "defaultClosedLidMode")
        self.hasAcknowledgedThermalWarning = defaults.bool(forKey: "hasAcknowledgedThermalWarning")

        setupClosedLidCallbacks()
    }

    /// Performs failsafe recovery check at application launch (see
    /// `ClosedLidController.performStartupRecovery()`), then refreshes
    /// `isSleepDisabledOutsideSession`. Returns the underlying task so callers (and tests)
    /// can await its completion; normal call sites can ignore the result.
    @discardableResult
    public func performStartupRecovery() -> Task<Void, Never> {
        let controller = closedLidController
        return Task { [weak self] in
            await controller.performStartupRecovery()
            await self?.refreshSleepState()
        }
    }

    public func clearLastAutomaticStopReason() {
        lastAutomaticStopReason = nil
    }

    public func startSession(
        duration: SessionDuration,
        allowDisplaySleep: Bool? = nil,
        closedLidMode: Bool? = nil
    ) async throws {
        try await enqueue {
            try await self.performStart(duration: duration, allowDisplaySleep: allowDisplaySleep, closedLidMode: closedLidMode)
        }
    }

    public func stopSession() async {
        try? await enqueue { await self.performStop() }
    }

    public func extendSession(by seconds: TimeInterval) async {
        try? await enqueue { await self.performExtend(by: seconds) }
    }

    /// Turns system sleep back on when it is disabled outside a Closed-Lid session (see
    /// `isSleepDisabledOutsideSession`), asking for administrator authentication if Meth's
    /// rule cannot be used.
    public func restoreNormalSleep() async throws {
        do {
            try await enqueue { try await self.closedLidController.restoreNormalSleep() }
        } catch {
            await refreshSleepState()
            throw error
        }
        await refreshSleepState()
    }

    /// Re-reads whether system sleep is disabled outside a Closed-Lid session. Cheap (one
    /// `pmset -g live`), so callers such as the menu can refresh on demand.
    public func refreshSleepState() async {
        sleepStateRefreshGeneration += 1
        let generation = sleepStateRefreshGeneration
        let disabled = await closedLidController.isSleepDisabledOutsideSession()
        // A newer refresh may have finished first; never overwrite its result.
        guard generation == sleepStateRefreshGeneration, disabled != isSleepDisabledOutsideSession else { return }
        isSleepDisabledOutsideSession = disabled
    }

    // MARK: - Closed-Lid support pass-through

    public func closedLidSupportStatus() async -> ClosedLidSupportStatus {
        await closedLidController.supportStatus()
    }

    public func installClosedLidSupport() async throws {
        try await closedLidController.installSupport()
    }

    public func uninstallClosedLidSupport() async throws {
        try await closedLidController.uninstallSupport()
        await refreshSleepState()
    }

    // MARK: - Serialized session operations

    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            try await operation()
        }
        lastOperation = Task { @MainActor in _ = await task.result }
        try await task.value
    }

    private func performStart(duration: SessionDuration, allowDisplaySleep: Bool?, closedLidMode: Bool?) async throws {
        // Stop any existing session cleanly without leaking assertions
        await performStop()

        let displaySleep = allowDisplaySleep ?? defaultAllowDisplaySleep
        let closedLid = closedLidMode ?? defaultClosedLidMode

        let newSession = Session(
            duration: duration,
            allowDisplaySleep: displaySleep,
            closedLidMode: closedLid
        )

        // 1. Acquire system idle sleep assertion
        let acquiredSystem: AssertionToken
        do {
            let id = try powerAssertionManager.createAssertion(
                type: .preventUserIdleSystemSleep,
                name: "Meth Keep Awake Session"
            )
            acquiredSystem = AssertionToken(id: id, type: .preventUserIdleSystemSleep, manager: powerAssertionManager)
        } catch {
            logger.error("Failed to acquire system idle sleep assertion: \(error.localizedDescription)")
            throw error
        }

        // 2. Acquire display sleep assertion if display sleep is NOT allowed
        var acquiredDisplay: AssertionToken?
        if !displaySleep {
            do {
                let id = try powerAssertionManager.createAssertion(
                    type: .preventUserIdleDisplaySleep,
                    name: "Meth Display Keep Awake"
                )
                acquiredDisplay = AssertionToken(id: id, type: .preventUserIdleDisplaySleep, manager: powerAssertionManager)
            } catch {
                logger.warning("Failed to acquire display sleep assertion: \(error.localizedDescription)")
            }
        }

        // 3. Activate Closed-Lid Mode if requested. If this fails, the whole session fails
        // rather than silently continuing in a downgraded, normal keep-awake-only mode: a
        // user who explicitly asked for Closed-Lid Mode should never be left thinking their
        // Mac will stay awake with the lid closed when it will not.
        if closedLid {
            let timeoutSeconds = newSession.remainingTime().map { Int(ceil($0)) }
            do {
                try await closedLidController.activate(timeoutSeconds: timeoutSeconds)
            } catch {
                logger.error("Failed to activate Closed-Lid Mode: \(error.localizedDescription)")
                acquiredDisplay?.release()
                acquiredSystem.release()
                throw error
            }
        }

        self.systemSleepAssertion = acquiredSystem
        self.displaySleepAssertion = acquiredDisplay
        self.activeSession = newSession
        scheduleExpiration(for: newSession)
        logger.info("Session started: duration=\(String(describing: duration)), displaySleep=\(displaySleep), closedLid=\(closedLid)")

        if closedLid {
            await refreshSleepState()
        }
    }

    private func performStop() async {
        guard let session = activeSession else { return }
        logger.info("Stopping active session: \(session.id)")

        // Cleared before the first suspension point, so the menu reflects the stop at once.
        cancelTimers()
        systemSleepAssertion?.release()
        displaySleepAssertion?.release()
        systemSleepAssertion = nil
        displaySleepAssertion = nil
        activeSession = nil
        remainingTime = nil

        guard session.closedLidMode else { return }

        // A failed revert used to be logged and nothing more: the menu bar went back to
        // "inactive" while the Mac was in fact still unable to sleep. Surface it instead.
        if await !closedLidController.deactivate() {
            lastAutomaticStopReason = "The session was stopped. \(Self.sleepNotRestoredAdvice)"
        }
        await refreshSleepState()
    }

    private func performExtend(by seconds: TimeInterval) async {
        guard let current = activeSession, !current.duration.isIndefinite else { return }

        var deadlineOverride: ContinuousClock.Instant?
        if case .preset = current.duration, let deadline = monotonicDeadline {
            deadlineOverride = deadline.advanced(by: .seconds(seconds))
        }

        let extended = current.extending(by: seconds)
        self.activeSession = extended
        scheduleExpiration(for: extended, presetDeadlineOverride: deadlineOverride)

        // Only re-arms the watchdog's time limit; never (re-)enables Closed-Lid Mode.
        if extended.closedLidMode, let remaining = remainingTime {
            await closedLidController.updateWatchdogTimeout(Int(ceil(remaining)))
        }

        logger.info("Extended session by \(seconds)s.")
    }

    // MARK: - Expiration (one authoritative mechanism + a cosmetic display refresh)

    private func scheduleExpiration(for session: Session, presetDeadlineOverride: ContinuousClock.Instant? = nil) {
        expirationTask?.cancel()
        expirationTask = nil
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil

        let sessionID = session.id
        switch session.duration {
        case .indefinite:
            monotonicDeadline = nil
            remainingTime = nil
            return

        case .preset(let seconds):
            let deadline = presetDeadlineOverride ?? Self.clock.now.advanced(by: .seconds(seconds))
            monotonicDeadline = deadline
            expirationTask = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: Self.clock)
                guard !Task.isCancelled else { return }
                await self?.handleExpiration(of: sessionID)
            }

        case .until(let targetDate):
            // Wall-clock by design: the user chose a real clock time, so this is
            // re-evaluated against `Date()` periodically to stay correct across manual
            // clock changes, rather than sleeping once for a fixed monotonic duration.
            monotonicDeadline = nil
            expirationTask = Task { [weak self] in
                while !Task.isCancelled {
                    let remaining = targetDate.timeIntervalSinceNow
                    if remaining <= 0 { break }
                    try? await Task.sleep(for: .seconds(min(remaining, 30.0)))
                }
                guard !Task.isCancelled else { return }
                await self?.handleExpiration(of: sessionID)
            }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRemainingTimeDisplay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayRefreshTimer = timer
        refreshRemainingTimeDisplay()
    }

    private func handleExpiration(of sessionID: UUID) async {
        try? await enqueue {
            // An extension queued ahead of this stop may have moved the deadline.
            guard let session = self.activeSession, session.id == sessionID, self.hasExpired(session) else { return }
            logger.info("Session timer expired naturally.")
            await self.performStop()
        }
    }

    private func hasExpired(_ session: Session) -> Bool {
        switch session.duration {
        case .indefinite:
            return false
        case .preset:
            return monotonicDeadline.map { Self.clock.now >= $0 } ?? true
        case .until(let targetDate):
            return targetDate <= Date()
        }
    }

    private func refreshRemainingTimeDisplay() {
        guard let active = activeSession else { return }
        switch active.duration {
        case .indefinite:
            remainingTime = nil
        case .preset:
            if let deadline = monotonicDeadline {
                let now = Self.clock.now
                remainingTime = now < deadline ? now.duration(to: deadline).timeInterval : 0
            } else {
                remainingTime = active.remainingTime()
            }
        case .until:
            remainingTime = active.remainingTime()
        }
    }

    private func cancelTimers() {
        expirationTask?.cancel()
        expirationTask = nil
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil
        monotonicDeadline = nil
    }

    // MARK: - Automatic Closed-Lid cutoffs

    private func setupClosedLidCallbacks() {
        let controller = closedLidController
        Task {
            await controller.setLowBatteryCutoffHandler { [weak self] sleepRestored in
                Task { @MainActor [weak self] in
                    await self?.handleClosedLidCutoff(
                        reason: "Your Closed-Lid session was stopped because the battery reached \(PowerSourceState.lowBatteryThreshold)% while the Mac was not connected to power.",
                        sleepRestored: sleepRestored
                    )
                }
            }
            await controller.setIntegrityFailureHandler { [weak self] reason, sleepRestored in
                Task { @MainActor [weak self] in
                    await self?.handleClosedLidCutoff(reason: reason, sleepRestored: sleepRestored)
                }
            }
        }
    }

    /// The controller has already turned Closed-Lid Mode off by itself (low battery, or
    /// support disappeared); end the session that relied on it and tell the user.
    private func handleClosedLidCutoff(reason: String, sleepRestored: Bool) async {
        logger.warning("Closed-Lid Mode stopped automatically: \(reason)")
        try? await enqueue {
            // A session started after the cutoff that turned Closed-Lid Mode back on is
            // unaffected; only one still claiming protection that no longer exists ends.
            let closedLidActive = await self.closedLidController.isClosedLidActive
            if self.activeSession?.closedLidMode == true, !closedLidActive {
                await self.performStop()
            }
            self.lastAutomaticStopReason = sleepRestored ? reason : "\(reason) \(Self.sleepNotRestoredAdvice)"
        }
        await refreshSleepState()
    }
}
