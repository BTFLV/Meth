import Foundation
import XCTest
@testable import MethCore

@MainActor
final class FailsafeRecoveryTests: XCTestCase {
    func testStartupRecoveryRevertsMethOwnedStaleState() async {
        let mockPrivileged = MockClosedLidPrivilegedService()
        // Simulate a previous crash: Meth had enabled the override (marker set) and never
        // got to clean it up.
        mockPrivileged.sleepDisabled = true
        mockPrivileged.ownershipMarkerSet = true

        let mockPower = MockPowerAssertionManager()
        let mockLid = MockLidStateMonitor()
        let mockSource = MockPowerSourceMonitor()
        let controller = ClosedLidController(
            privilegedService: mockPrivileged,
            lidMonitor: mockLid,
            powerMonitor: mockSource,
            watchdogClient: makeIsolatedWatchdogClient()
        )

        let sessionManager = SessionManager(
            powerAssertionManager: mockPower,
            closedLidController: controller,
            privilegedService: mockPrivileged
        )

        await sessionManager.performStartupRecovery().value

        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.restoreFailsafeCallsCount, 1)
    }

    func testStartupRecoveryDoesNothingIfSleepAlreadyEnabled() async {
        let mockPrivileged = MockClosedLidPrivilegedService()
        mockPrivileged.sleepDisabled = false
        mockPrivileged.ownershipMarkerSet = true

        let mockPower = MockPowerAssertionManager()
        let mockLid = MockLidStateMonitor()
        let mockSource = MockPowerSourceMonitor()
        let controller = ClosedLidController(
            privilegedService: mockPrivileged,
            lidMonitor: mockLid,
            powerMonitor: mockSource,
            watchdogClient: makeIsolatedWatchdogClient()
        )

        let sessionManager = SessionManager(
            powerAssertionManager: mockPower,
            closedLidController: controller,
            privilegedService: mockPrivileged
        )

        await sessionManager.performStartupRecovery().value

        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.restoreFailsafeCallsCount, 0)
        XCTAssertFalse(mockPrivileged.ownershipMarkerSet)
    }

    func testStartupRecoveryNeverClobbersStateItDoesNotOwn() async {
        let mockPrivileged = MockClosedLidPrivilegedService()
        // SleepDisabled is enabled, but Meth never set the ownership marker -- e.g. an
        // administrator or another tool configured this deliberately.
        mockPrivileged.sleepDisabled = true
        mockPrivileged.ownershipMarkerSet = false

        let mockPower = MockPowerAssertionManager()
        let mockLid = MockLidStateMonitor()
        let mockSource = MockPowerSourceMonitor()
        let controller = ClosedLidController(
            privilegedService: mockPrivileged,
            lidMonitor: mockLid,
            powerMonitor: mockSource,
            watchdogClient: makeIsolatedWatchdogClient()
        )

        let sessionManager = SessionManager(
            powerAssertionManager: mockPower,
            closedLidController: controller,
            privilegedService: mockPrivileged
        )

        await sessionManager.performStartupRecovery().value

        // Must be left completely untouched.
        XCTAssertTrue(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.restoreFailsafeCallsCount, 0)
        XCTAssertEqual(mockPrivileged.disableCallsCount, 0)
    }
}
