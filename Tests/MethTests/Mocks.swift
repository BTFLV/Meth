import Foundation
import MethCore

/// Tests must never spawn the real MethWatchdog binary or touch the real shared
/// UserDefaults suite (`ClosedLidSharedState.defaults`), so every test that constructs a
/// `ClosedLidController` should use this instead of `WatchdogClient()`.
func makeIsolatedWatchdogClient() -> WatchdogClient {
    WatchdogClient(
        sharedDefaults: UserDefaults(suiteName: "com.meth.tests.\(UUID().uuidString)")!,
        binaryLocator: { nil }
    )
}

final class MockPowerAssertionManager: PowerAssertionManaging, @unchecked Sendable {
    private let lock = NSLock()
    var createdAssertions: [(type: PowerAssertionType, name: String, id: PowerAssertionID)] = []
    var releasedAssertionIDs: [PowerAssertionID] = []
    var nextAssertionID: PowerAssertionID = 100
    var shouldFailCreation = false

    func createAssertion(type: PowerAssertionType, name: String) throws -> PowerAssertionID {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailCreation {
            throw PowerAssertionError.creationFailed(-1)
        }
        let id = nextAssertionID
        nextAssertionID += 1
        createdAssertions.append((type, name, id))
        return id
    }

    func releaseAssertion(id: PowerAssertionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        releasedAssertionIDs.append(id)
        return true
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return createdAssertions.count - releasedAssertionIDs.count
    }
}

final class MockLidStateMonitor: LidStateMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    var simulatedState: LidState = .open
    var isMonitoring = false
    var onLidStateChange: (@Sendable (LidState) -> Void)?

    var currentState: LidState {
        lock.lock()
        defer { lock.unlock() }
        return simulatedState
    }

    func startMonitoring() {
        lock.lock()
        isMonitoring = true
        lock.unlock()
    }

    func stopMonitoring() {
        lock.lock()
        isMonitoring = false
        lock.unlock()
    }

    func triggerStateChange(_ newState: LidState) {
        lock.lock()
        simulatedState = newState
        let callback = onLidStateChange
        lock.unlock()
        callback?(newState)
    }
}

final class MockPowerSourceMonitor: PowerSourceMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    var simulatedState: PowerSourceState = .unknown
    var isMonitoring = false
    var onPowerSourceChange: (@Sendable (PowerSourceState) -> Void)?

    var currentState: PowerSourceState {
        lock.lock()
        defer { lock.unlock() }
        return simulatedState
    }

    func startMonitoring() {
        lock.lock()
        isMonitoring = true
        lock.unlock()
    }

    func stopMonitoring() {
        lock.lock()
        isMonitoring = false
        lock.unlock()
    }

    func triggerPowerChange(_ newState: PowerSourceState) {
        lock.lock()
        simulatedState = newState
        let callback = onPowerSourceChange
        lock.unlock()
        callback?(newState)
    }
}

final class MockClosedLidPrivilegedService: ClosedLidPrivilegedManaging, @unchecked Sendable {
    private let lock = NSLock()
    var status: ClosedLidSupportStatus = .installed
    var sleepDisabled: Bool = false
    var displaySleepTriggeredCount: Int = 0
    var enableCallsCount: Int = 0
    var disableCallsCount: Int = 0
    var ownershipMarkerSet: Bool = false
    var restoreFailsafeResult: Bool = true
    var restoreFailsafeCallsCount: Int = 0
    /// Simulates a privileged revert that fails (e.g. the sudoers rule became unusable),
    /// which must never be reported to the user as a clean stop.
    var disableShouldFail: Bool = false
    /// When set, `disableSleepDisabled()` blocks until the semaphore is signalled, so tests
    /// can act while a Closed-Lid deactivation is still in progress.
    var disableGate: DispatchSemaphore?
    var administratorRestoreCallsCount: Int = 0
    var administratorRestoreError: ClosedLidError?

    func supportStatus() -> ClosedLidSupportStatus {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    func isSleepDisabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sleepDisabled
    }

    // Like the real service, enabling records Meth's ownership before mutating, and a
    // successful revert clears it.
    func enableSleepDisabled() throws {
        lock.lock()
        defer { lock.unlock() }
        guard status == .installed else { throw ClosedLidError.supportNotInstalled }
        ownershipMarkerSet = true
        sleepDisabled = true
        enableCallsCount += 1
    }

    func disableSleepDisabled() throws {
        lock.lock()
        disableCallsCount += 1
        let gate = disableGate
        lock.unlock()
        gate?.wait()

        lock.lock()
        defer { lock.unlock() }
        if disableShouldFail {
            throw ClosedLidError.executionFailed(
                command: "sudo -n pmset -a disablesleep 0",
                exitCode: 1,
                stderr: "simulated failure"
            )
        }
        sleepDisabled = false
        ownershipMarkerSet = false
    }

    func putDisplayToSleep() {
        lock.lock()
        defer { lock.unlock() }
        displaySleepTriggeredCount += 1
    }

    func installSupport() throws {
        lock.lock()
        defer { lock.unlock() }
        status = .installed
    }

    func uninstallSupport() throws {
        lock.lock()
        defer { lock.unlock() }
        status = .notInstalled
        sleepDisabled = false
    }

    func restoreSleepDisabledWithAdministratorPrivileges() throws {
        lock.lock()
        defer { lock.unlock() }
        administratorRestoreCallsCount += 1
        if let administratorRestoreError {
            throw administratorRestoreError
        }
        sleepDisabled = false
        ownershipMarkerSet = false
    }

    @discardableResult
    func restoreSleepDisabledForFailsafe(maxAttempts: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        restoreFailsafeCallsCount += 1
        if restoreFailsafeResult {
            sleepDisabled = false
            ownershipMarkerSet = false
        }
        return restoreFailsafeResult
    }

    func isOwnershipMarkerSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownershipMarkerSet
    }

    func clearOwnershipMarker() {
        lock.lock()
        defer { lock.unlock() }
        ownershipMarkerSet = false
    }
}

/// Records every command issued to it instead of running anything, so tests can assert
/// which commands a real `ClosedLidPrivilegedService` does (and does not) execute.
final class RecordingProcessExecutor: ProcessExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocations: [(executable: String, arguments: [String])] = []
    var resultProvider: (String, [String]) -> (exitCode: Int32, stdout: String, stderr: String) = { _, _ in (0, "", "") }

    func execute(executable: String, arguments: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        lock.lock()
        invocations.append((executable, arguments))
        lock.unlock()
        return resultProvider(executable, arguments)
    }

    var everMutatedDisableSleep: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invocations.contains { call in
            call.arguments.contains("disablesleep") && !call.arguments.contains("-l")
        }
    }
}


/// Records the scripts `ClosedLidPrivilegedService` would run through the administrator
/// prompt instead of running them.
final class RecordingAdministratorRunner: AdministratorScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [String] = []
    var error: AdministratorScriptError?

    func runAsAdministrator(_ shellCommand: String) throws {
        lock.lock()
        defer { lock.unlock() }
        commands.append(shellCommand)
        if let error {
            throw error
        }
    }
}

/// A `pmset -g live` reply reporting the given `SleepDisabled` value.
func pmsetLiveOutput(sleepDisabled: Bool) -> String {
    "System-wide power settings:\n SleepDisabled\t\t\(sleepDisabled ? 1 : 0)\n"
}
