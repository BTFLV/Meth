import Foundation
#if canImport(XCTest)
import XCTest
#endif
@testable import MethCore

@MainActor
final class FailsafeRecoveryTests: XCTestCase {
    func testStartupRecoveryCleansStaleSleepDisabledState() {
        let mockPrivileged = MockClosedLidPrivilegedService()
        // Simulate machine having SleepDisabled=true left behind by a crash
        mockPrivileged.sleepDisabled = true

        let mockPower = MockPowerAssertionManager()
        let mockLid = MockLidStateMonitor()
        let mockSource = MockPowerSourceMonitor()
        let controller = ClosedLidController(
            privilegedService: mockPrivileged,
            lidMonitor: mockLid,
            powerMonitor: mockSource
        )

        let sessionManager = SessionManager(
            powerAssertionManager: mockPower,
            closedLidController: controller,
            privilegedService: mockPrivileged
        )

        sessionManager.performStartupRecovery()

        // After startup recovery, sleepDisabled must be reverted to false
        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.disableCallsCount, 1)
    }

    func testStartupRecoveryDoesNothingIfSleepAlreadyEnabled() {
        let mockPrivileged = MockClosedLidPrivilegedService()
        mockPrivileged.sleepDisabled = false

        let mockPower = MockPowerAssertionManager()
        let mockLid = MockLidStateMonitor()
        let mockSource = MockPowerSourceMonitor()
        let controller = ClosedLidController(
            privilegedService: mockPrivileged,
            lidMonitor: mockLid,
            powerMonitor: mockSource
        )

        let sessionManager = SessionManager(
            powerAssertionManager: mockPower,
            closedLidController: controller,
            privilegedService: mockPrivileged
        )

        sessionManager.performStartupRecovery()

        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.disableCallsCount, 0)
    }
}
