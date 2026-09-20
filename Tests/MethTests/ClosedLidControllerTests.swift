import Foundation
#if canImport(XCTest)
import XCTest
#endif
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
            powerMonitor: mockSource
        )
    }

    override func tearDown() {
        controller.deactivate()
        super.tearDown()
    }

    func testActivationAndDeactivationLifecycle() throws {
        XCTAssertFalse(controller.isClosedLidActive)
        XCTAssertFalse(mockLid.isMonitoring)
        XCTAssertFalse(mockSource.isMonitoring)

        try controller.activate(timeoutSeconds: 300)
        XCTAssertTrue(controller.isClosedLidActive)
        XCTAssertTrue(mockPrivileged.sleepDisabled)
        XCTAssertTrue(mockLid.isMonitoring)
        XCTAssertTrue(mockSource.isMonitoring)

        controller.deactivate()
        XCTAssertFalse(controller.isClosedLidActive)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertFalse(mockLid.isMonitoring)
        XCTAssertFalse(mockSource.isMonitoring)
    }

    func testLidCloseTriggersDisplaySleep() throws {
        try controller.activate()
        XCTAssertEqual(mockPrivileged.displaySleepTriggeredCount, 0)

        // Simulate closing the laptop lid
        mockLid.triggerStateChange(.closed)

        XCTAssertEqual(mockPrivileged.displaySleepTriggeredCount, 1)
    }

    func testLowBatteryTriggersSafetyCutoff() throws {
        let expectation = expectation(description: "Low battery cutoff callback")
        controller.onLowBatteryCutoff = {
            expectation.fulfill()
        }

        try controller.activate()
        XCTAssertTrue(controller.isClosedLidActive)

        // Simulate battery dropping to 8% without AC power
        let lowBatteryState = PowerSourceState(
            hasExternalPower: false,
            isCharging: false,
            batteryLevel: 8,
            isLowBattery: true
        )
        mockSource.triggerPowerChange(lowBatteryState)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(controller.isClosedLidActive)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
    }

    func testAppleSiliconPowerSourceTransitionReEnforcesSleepDisabled() throws {
        try controller.activate()
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

        // Controller should detect that SleepDisabled was dropped and re-enable it
        XCTAssertTrue(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.enableCallsCount, 2)
    }
}
