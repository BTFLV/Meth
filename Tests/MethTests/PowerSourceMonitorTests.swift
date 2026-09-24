import Foundation
import XCTest
@testable import MethCore

final class PowerSourceMonitorTests: XCTestCase {
    private final class Reading: @unchecked Sendable {
        private let lock = NSLock()
        private var state: PowerSourceState
        init(_ state: PowerSourceState) { self.state = state }
        var value: PowerSourceState {
            get { lock.lock(); defer { lock.unlock() }; return state }
            set { lock.lock(); state = newValue; lock.unlock() }
        }
    }

    private static let healthy = PowerSourceState(hasExternalPower: false, isCharging: false, batteryLevel: 80, isLowBattery: false)
    private static let low = PowerSourceState(hasExternalPower: false, isCharging: false, batteryLevel: 7, isLowBattery: true)

    /// Regression test: the cached state was only refreshed while monitoring, so outside a
    /// Closed-Lid session it could be hours old -- e.g. still showing the battery level from
    /// when Meth launched.
    func testCurrentStateIsReadLiveWhileNotMonitoring() {
        let reading = Reading(Self.healthy)
        let monitor = PowerSourceMonitor(stateProvider: { reading.value })
        XCTAssertEqual(monitor.currentState, Self.healthy)

        reading.value = Self.low

        XCTAssertEqual(monitor.currentState, Self.low)
    }

    /// End to end: activation must see the battery as it is now, not as it was when the
    /// monitor was created.
    func testClosedLidActivationUsesTheCurrentBatteryLevel() async {
        let reading = Reading(Self.healthy)
        let privileged = MockClosedLidPrivilegedService()
        let controller = ClosedLidController(
            privilegedService: privileged,
            lidMonitor: MockLidStateMonitor(),
            powerMonitor: PowerSourceMonitor(stateProvider: { reading.value }),
            watchdogClient: makeIsolatedWatchdogClient()
        )

        reading.value = Self.low

        do {
            try await controller.activate()
            XCTFail("Expected activation to be refused on low battery")
        } catch {
            XCTAssertEqual(error as? ClosedLidError, .batteryTooLow(7))
        }
        XCTAssertFalse(privileged.sleepDisabled)
    }
}
