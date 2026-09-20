import Foundation
import MethCore

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
    var isSupportInstalled: Bool = true
    var sleepDisabled: Bool = false
    var displaySleepTriggeredCount: Int = 0
    var enableCallsCount: Int = 0
    var disableCallsCount: Int = 0

    func isSleepDisabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sleepDisabled
    }

    func enableSleepDisabled() throws {
        lock.lock()
        defer { lock.unlock() }
        guard isSupportInstalled else { throw ClosedLidError.supportNotInstalled }
        sleepDisabled = true
        enableCallsCount += 1
    }

    func disableSleepDisabled() throws {
        lock.lock()
        defer { lock.unlock() }
        sleepDisabled = false
        disableCallsCount += 1
    }

    func putDisplayToSleep() {
        lock.lock()
        defer { lock.unlock() }
        displaySleepTriggeredCount += 1
    }

    func installSupport() throws {
        lock.lock()
        defer { lock.unlock() }
        isSupportInstalled = true
    }

    func uninstallSupport() throws {
        lock.lock()
        defer { lock.unlock() }
        isSupportInstalled = false
        sleepDisabled = false
    }
}

