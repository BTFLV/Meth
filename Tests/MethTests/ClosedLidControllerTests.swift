import Foundation
import XCTest
@testable import MethCore

final class ClosedLidControllerTests: XCTestCase {
    var mockPrivileged: MockClosedLidPrivilegedService!
    var mockLid: MockLidStateMonitor!
    var mockSource: MockPowerSourceMonitor!
    var controller: ClosedLidController!

    override func setUp() {
        super.setUp()
        mockPrivileged = MockClosedLidPrivilegedService()
        mockLid = MockLidStateMonitor()
        mockSource = MockPowerSourceMonitor()

        controller = ClosedLidController(
            privilegedService: mockPrivileged,
            lidMonitor: mockLid,
            powerMonitor: mockSource,
            watchdogClient: makeIsolatedWatchdogClient()
        )
    }

    override func tearDown() async throws {
        await controller.deactivate()
        try await super.tearDown()
    }

    func testActivationAndDeactivationLifecycle() async throws {
        var active = await controller.isClosedLidActive
        XCTAssertFalse(active)
        XCTAssertFalse(mockLid.isMonitoring)
        XCTAssertFalse(mockSource.isMonitoring)

        try await controller.activate(timeoutSeconds: 300)
        active = await controller.isClosedLidActive
        XCTAssertTrue(active)
        XCTAssertTrue(mockPrivileged.sleepDisabled)
        XCTAssertTrue(mockLid.isMonitoring)
        XCTAssertTrue(mockSource.isMonitoring)

        await controller.deactivate()
        active = await controller.isClosedLidActive
        XCTAssertFalse(active)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertFalse(mockLid.isMonitoring)
        XCTAssertFalse(mockSource.isMonitoring)
    }

    func testFailedActivationLeavesNoStaleActiveState() async {
        mockPrivileged.status = .notInstalled

        do {
            try await controller.activate()
            XCTFail("Expected activation to throw")
        } catch {
            XCTAssertEqual(error as? ClosedLidError, .supportNotInstalled)
        }

        let active = await controller.isClosedLidActive
        XCTAssertFalse(active)
        let state = await controller.currentState
        XCTAssertEqual(state, .inactive)
        XCTAssertFalse(mockLid.isMonitoring)
        XCTAssertFalse(mockSource.isMonitoring)
    }

    func testActivationImmediatelyFollowedByStopLeavesConsistentState() async throws {
        try await controller.activate()
        await controller.deactivate()

        let active = await controller.isClosedLidActive
        XCTAssertFalse(active)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
    }

    func testUninstallSupportIsRejectedWhileSessionActive() async throws {
        try await controller.activate()

        do {
            try await controller.uninstallSupport()
            XCTFail("Expected uninstall to be rejected while active")
        } catch {
            XCTAssertEqual(error as? ClosedLidError, .activeSessionInProgress)
        }

        // The underlying privileged uninstall must never have been reached.
        XCTAssertEqual(mockPrivileged.supportStatus(), .installed)
    }

    func testUninstallSupportSucceedsWhileInactive() async throws {
        try await controller.uninstallSupport()
        XCTAssertEqual(mockPrivileged.supportStatus(), .notInstalled)
    }

    func testLidCloseTriggersDisplaySleep() async throws {
        try await controller.activate()
        XCTAssertEqual(mockPrivileged.displaySleepTriggeredCount, 0)

        // Simulate closing the laptop lid
        mockLid.triggerStateChange(.closed)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mockPrivileged.displaySleepTriggeredCount, 1)
    }

    func testLowBatteryTriggersSafetyCutoff() async throws {
        let expectation = expectation(description: "Low battery cutoff callback")
        await controller.setLowBatteryCutoffHandler {
            expectation.fulfill()
        }

        try await controller.activate()
        var active = await controller.isClosedLidActive
        XCTAssertTrue(active)

        // Simulate battery dropping to 8% without AC power
        let lowBatteryState = PowerSourceState(
            hasExternalPower: false,
            isCharging: false,
            batteryLevel: 8,
            isLowBattery: true
        )
        mockSource.triggerPowerChange(lowBatteryState)

        await fulfillment(of: [expectation], timeout: 1.0)
        active = await controller.isClosedLidActive
        XCTAssertFalse(active)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
    }

    func testAppleSiliconPowerSourceTransitionReEnforcesSleepDisabled() async throws {
        try await controller.activate()
        XCTAssertTrue(mockPrivileged.sleepDisabled)

        // Simulate macOS powerd clearing SleepDisabled during AC unplug
        mockPrivileged.sleepDisabled = false

        // Transition from AC to battery (above safe threshold)
        let batteryState = PowerSourceState(
            hasExternalPower: false,
            isCharging: false,
            batteryLevel: 80,
            isLowBattery: false
        )
        mockSource.triggerPowerChange(batteryState)
        try await Task.sleep(for: .milliseconds(50))

        // Controller should detect that SleepDisabled was dropped and re-enable it
        XCTAssertTrue(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.enableCallsCount, 2)
    }

    func testPowerSourceReassertionFailureAfterSupportRemovalStopsSession() async throws {
        try await controller.activate()

        let expectation = expectation(description: "Integrity failure callback")
        await controller.setIntegrityFailureHandler { _ in
            expectation.fulfill()
        }

        // Simulate support being removed out from under an active session, and the kernel
        // having cleared the flag independently.
        mockPrivileged.sleepDisabled = false
        mockPrivileged.status = .notInstalled

        let batteryState = PowerSourceState(hasExternalPower: true, isCharging: true, batteryLevel: 90, isLowBattery: false)
        mockSource.triggerPowerChange(batteryState)

        await fulfillment(of: [expectation], timeout: 1.0)
        let active = await controller.isClosedLidActive
        XCTAssertFalse(active, "A reassertion failure with support gone must not leave the session claiming to be active.")
    }
}
