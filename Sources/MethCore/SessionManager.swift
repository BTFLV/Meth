import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.meth.app", category: "SessionManager")

@MainActor
public final class SessionManager: ObservableObject {
    public static let shared = SessionManager()

    @Published public private(set) var activeSession: Session?
    @Published public private(set) var remainingTime: TimeInterval?
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
    private let closedLidController: ClosedLidController
    private let privilegedService: any ClosedLidPrivilegedManaging

    private var systemSleepAssertion: PowerAssertionID?
    private var displaySleepAssertion: PowerAssertionID?

    private var countdownTimer: Timer?
    private var expirationTimer: Timer?

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

        setupLowBatteryHandler()
    }

    /// Performs failsafe recovery check at application launch.
    /// If macOS has SleepDisabled = 1 left over from a previous crash or reboot, revert it immediately.
    public func performStartupRecovery() {
        if privilegedService.isSleepDisabled() {
            logger.warning("Startup recovery: Found stale SleepDisabled=1 without active Meth session. Reverting to 0.")
            try? privilegedService.disableSleepDisabled()
        }
    }

    public func startSession(
        duration: SessionDuration,
        allowDisplaySleep: Bool? = nil,
        closedLidMode: Bool? = nil
    ) throws {
        // Stop any existing session cleanly without leaking assertions
        if activeSession != nil {
            stopSession()
        }

        let displaySleep = allowDisplaySleep ?? defaultAllowDisplaySleep
        let closedLid = closedLidMode ?? defaultClosedLidMode

        let newSession = Session(
            duration: duration,
            allowDisplaySleep: displaySleep,
            closedLidMode: closedLid
        )

        // 1. Acquire system idle sleep assertion
        do {
            self.systemSleepAssertion = try powerAssertionManager.createAssertion(
                type: .preventUserIdleSystemSleep,
                name: "Meth Keep Awake Session"
            )
        } catch {
            logger.error("Failed to acquire system idle sleep assertion: \(error.localizedDescription)")
            cleanupAssertions()
            throw error
        }

        // 2. Acquire display sleep assertion if display sleep is NOT allowed
        if !displaySleep {
            do {
                self.displaySleepAssertion = try powerAssertionManager.createAssertion(
                    type: .preventUserIdleDisplaySleep,
                    name: "Meth Display Keep Awake"
                )
            } catch {
                logger.warning("Failed to acquire display sleep assertion: \(error.localizedDescription)")
            }
        }

        // 3. Activate Closed-Lid Mode if requested
        if closedLid {
            let timeoutSeconds: Int?
            if let seconds = newSession.remainingTime() {
                timeoutSeconds = Int(ceil(seconds))
            } else {
                timeoutSeconds = nil
            }

            do {
                try closedLidController.activate(timeoutSeconds: timeoutSeconds)
            } catch {
                logger.error("Failed to activate Closed-Lid Mode: \(error.localizedDescription)")
                cleanupAssertions()
                throw error
            }
        }

        self.activeSession = newSession
        self.remainingTime = newSession.remainingTime()

        setupTimers(for: newSession)
        logger.info("Session started: duration=\(String(describing: duration)), displaySleep=\(displaySleep), closedLid=\(closedLid)")
    }

    public func stopSession() {
        guard let session = activeSession else { return }
        logger.info("Stopping active session: \(session.id)")

        cancelTimers()
        cleanupAssertions()

        if session.closedLidMode {
            closedLidController.deactivate()
        }

        self.activeSession = nil
        self.remainingTime = nil
    }

    public func extendSession(by seconds: TimeInterval) {
        guard let current = activeSession, !current.duration.isIndefinite else { return }

        let extended = current.extending(by: seconds)
        self.activeSession = extended
        self.remainingTime = extended.remainingTime()

        if extended.closedLidMode, let remaining = self.remainingTime {
            try? closedLidController.activate(timeoutSeconds: Int(ceil(remaining)))
        }

        setupTimers(for: extended)
        logger.info("Extended session by \(seconds)s. New remaining: \(String(describing: self.remainingTime))s")
    }

    private func setupTimers(for session: Session) {
        cancelTimers()

        guard let remaining = session.remainingTime() else {
            // Indefinite session: no timer needed
            return
        }

        // Expiration timer
        let expTimer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                logger.info("Session timer expired naturally.")
                self?.stopSession()
            }
        }
        RunLoop.main.add(expTimer, forMode: .common)
        self.expirationTimer = expTimer

        // Countdown update timer (every 1 second)
        let cdTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let active = self.activeSession else { return }
                let rem = active.remainingTime()
                self.remainingTime = rem
                if active.isExpired() {
                    self.stopSession()
                }
            }
        }
        RunLoop.main.add(cdTimer, forMode: .common)
        self.countdownTimer = cdTimer
    }

    private func cancelTimers() {
        expirationTimer?.invalidate()
        expirationTimer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    private func cleanupAssertions() {
        if let displayId = displaySleepAssertion {
            _ = powerAssertionManager.releaseAssertion(id: displayId)
            displaySleepAssertion = nil
        }
        if let systemId = systemSleepAssertion {
            _ = powerAssertionManager.releaseAssertion(id: systemId)
            systemSleepAssertion = nil
        }
    }

    private func setupLowBatteryHandler() {
        closedLidController.onLowBatteryCutoff = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                logger.warning("Low battery cutoff received: stopping active session.")
                self.stopSession()
            }
        }
    }
}

