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

    @Published public private(set) var activeSession: Session?
    @Published public private(set) var remainingTime: TimeInterval?
    /// Set when a session was stopped or downgraded automatically (low battery, integrity
    /// failure). Cleared by the UI after being surfaced once.
    @Published public private(set) var lastAutomaticStopReason: String?
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

    /// Performs failsafe recovery check at application launch. Only acts on state Meth
    /// believes it owns (see `ClosedLidPrivilegedManaging.isOwnershipMarkerSet`), so a
    /// `SleepDisabled` value left by another tool or an administrator is never clobbered.
    /// Returns the underlying task so callers (and tests) can await its completion; normal
    /// call sites can ignore the result and let it run in the background.
    @discardableResult
    public func performStartupRecovery() -> Task<Void, Never> {
        let service = privilegedService
        return Task.detached(priority: .utility) {
            guard service.isOwnershipMarkerSet() else {
                if service.isSleepDisabled() {
                    logger.notice("SleepDisabled is currently enabled but not owned by Meth; leaving system state untouched.")
                }
                return
            }
            if service.isSleepDisabled() {
                logger.warning("Startup recovery: reverting Meth-owned SleepDisabled state left over from a previous session.")
                service.restoreSleepDisabledForFailsafe(maxAttempts: 3)
            } else {
                service.clearOwnershipMarker()
            }
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
        // Stop any existing session cleanly without leaking assertions
        if activeSession != nil {
            await stopSession()
        }

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
    }

    public func stopSession() async {
        guard let session = activeSession else { return }
        logger.info("Stopping active session: \(session.id)")

        cancelTimers()

        systemSleepAssertion?.release()
        displaySleepAssertion?.release()
        systemSleepAssertion = nil
        displaySleepAssertion = nil

        var closedLidRestored = true
        if session.closedLidMode {
            closedLidRestored = await closedLidController.deactivate()
        }

        self.activeSession = nil
        self.remainingTime = nil

        // A failed revert used to be logged and nothing more: the menu bar went back to
        // "inactive" while the Mac was in fact still unable to sleep. Surface it instead.
        if !closedLidRestored {
            self.lastAutomaticStopReason = "The session was stopped, but normal sleep behavior could not be restored. Your Mac may still refuse to sleep with the lid closed. Meth's watchdog will keep retrying; if the problem persists, reinstall Closed-Lid Support in Settings or run 'sudo pmset -a disablesleep 0' in Terminal."
        }
    }

    public func extendSession(by seconds: TimeInterval) async {
        guard let current = activeSession, !current.duration.isIndefinite else { return }

        var deadlineOverride: ContinuousClock.Instant?
        if case .preset = current.duration, let deadline = monotonicDeadline {
            deadlineOverride = deadline.advanced(by: .seconds(seconds))
        }

        let extended = current.extending(by: seconds)
        self.activeSession = extended
        scheduleExpiration(for: extended, presetDeadlineOverride: deadlineOverride)

        if extended.closedLidMode, let remaining = remainingTime {
            do {
                try await closedLidController.activate(timeoutSeconds: Int(ceil(remaining)))
            } catch {
                logger.error("Failed to extend Closed-Lid watchdog timeout: \(error.localizedDescription)")
            }
        }

        logger.info("Extended session by \(seconds)s.")
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
    }

    // MARK: - Expiration (one authoritative mechanism + a cosmetic display refresh)

    private func scheduleExpiration(for session: Session, presetDeadlineOverride: ContinuousClock.Instant? = nil) {
        expirationTask?.cancel()
        expirationTask = nil
        displayRefreshTimer?.invalidate()
        displayRefreshTimer = nil

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
                await self?.handleExpiration()
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
                await self?.handleExpiration()
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

    private func handleExpiration() async {
        logger.info("Session timer expired naturally.")
        await stopSession()
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

    private func setupClosedLidCallbacks() {
        let controller = closedLidController
        Task {
            await controller.setLowBatteryCutoffHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    logger.warning("Low battery cutoff received: stopping active session.")
                    await self.stopSession()
                    self.lastAutomaticStopReason = "Closed-Lid Mode was stopped automatically because the battery reached the safety threshold."
                }
            }
            await controller.setIntegrityFailureHandler { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    logger.warning("Closed-Lid integrity failure: \(reason)")
                    await self.stopSession()
                    self.lastAutomaticStopReason = reason
                }
            }
        }
    }
}
