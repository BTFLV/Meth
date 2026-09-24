import Foundation
import XCTest
@testable import MethCore

@MainActor
final class SessionManagerTests: XCTestCase {
    var mockPower: MockPowerAssertionManager!
    var mockPrivileged: MockClosedLidPrivilegedService!
    var mockLid: MockLidStateMonitor!
    var mockSource: MockPowerSourceMonitor!
    var closedLidController: ClosedLidController!
    var sessionManager: SessionManager!

    override func setUp() {
        super.setUp()
        mockPower = MockPowerAssertionManager()
        mockPrivileged = MockClosedLidPrivilegedService()
        mockLid = MockLidStateMonitor()
        mockSource = MockPowerSourceMonitor()

        closedLidController = ClosedLidController(
            privilegedService: mockPrivileged,
            lidMonitor: mockLid,
            powerMonitor: mockSource,
            watchdogClient: makeIsolatedWatchdogClient()
        )

        sessionManager = SessionManager(
            powerAssertionManager: mockPower,
            closedLidController: closedLidController,
            privilegedService: mockPrivileged
        )
    }

    override func tearDown() async throws {
        await sessionManager.stopSession()
        try await super.tearDown()
    }

    func testStartNormalSessionWithDisplaySleepAllowed() async throws {
        try await sessionManager.startSession(
            duration: .preset(3600),
            allowDisplaySleep: true,
            closedLidMode: false
        )

        XCTAssertTrue(sessionManager.isSessionActive)
        XCTAssertEqual(mockPower.createdAssertions.count, 1)
        XCTAssertEqual(mockPower.createdAssertions.first?.type, .preventUserIdleSystemSleep)
        let closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertFalse(closedLidActive)
    }

    func testStartSessionWithDisplaySleepDisallowed() async throws {
        try await sessionManager.startSession(
            duration: .preset(3600),
            allowDisplaySleep: false,
            closedLidMode: false
        )

        XCTAssertTrue(sessionManager.isSessionActive)
        // System sleep + Display sleep = 2 assertions
        XCTAssertEqual(mockPower.createdAssertions.count, 2)
        let types = mockPower.createdAssertions.map { $0.type }
        XCTAssertTrue(types.contains(.preventUserIdleSystemSleep))
        XCTAssertTrue(types.contains(.preventUserIdleDisplaySleep))
    }

    func testStartClosedLidSession() async throws {
        try await sessionManager.startSession(
            duration: .preset(1800),
            allowDisplaySleep: true,
            closedLidMode: true
        )

        XCTAssertTrue(sessionManager.isSessionActive)
        let closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertTrue(closedLidActive)
        XCTAssertTrue(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.enableCallsCount, 1)
    }

    func testStopSessionCleansUpAllState() async throws {
        try await sessionManager.startSession(
            duration: .preset(1800),
            allowDisplaySleep: false,
            closedLidMode: true
        )

        XCTAssertTrue(sessionManager.isSessionActive)
        var closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertTrue(closedLidActive)

        await sessionManager.stopSession()

        XCTAssertFalse(sessionManager.isSessionActive)
        XCTAssertNil(sessionManager.activeSession)
        XCTAssertEqual(mockPower.activeCount, 0)
        closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertFalse(closedLidActive)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.disableCallsCount, 1)
    }

    func testSessionReplacementSafelyCleansUpOldSession() async throws {
        try await sessionManager.startSession(
            duration: .preset(3600),
            allowDisplaySleep: false,
            closedLidMode: false
        )

        XCTAssertEqual(mockPower.createdAssertions.count, 2)
        XCTAssertEqual(mockPower.releasedAssertionIDs.count, 0)

        // Replace session with a 15-minute closed-lid session
        try await sessionManager.startSession(
            duration: .preset(900),
            allowDisplaySleep: true,
            closedLidMode: true
        )

        // Previous 2 assertions must be released, new 1 assertion created
        XCTAssertEqual(mockPower.releasedAssertionIDs.count, 2)
        XCTAssertEqual(mockPower.activeCount, 1)
        let closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertTrue(closedLidActive)
    }

    func testExtendSession() async throws {
        try await sessionManager.startSession(
            duration: .preset(600),
            allowDisplaySleep: true,
            closedLidMode: false
        )

        let initialRemaining = sessionManager.remainingTime ?? 0
        await sessionManager.extendSession(by: 900)
        let extendedRemaining = sessionManager.remainingTime ?? 0

        XCTAssertGreaterThan(extendedRemaining, initialRemaining + 800)
    }

    func testClosedLidSupportNotInstalledThrows() async {
        mockPrivileged.status = .notInstalled

        do {
            try await sessionManager.startSession(
                duration: .preset(600),
                allowDisplaySleep: true,
                closedLidMode: true
            )
            XCTFail("Expected startSession to throw")
        } catch {
            guard let clError = error as? ClosedLidError else {
                XCTFail("Expected ClosedLidError, got \(error)")
                return
            }
            XCTAssertEqual(clError, .supportNotInstalled)
        }

        // Must not leak any assertions if startup throws, and must not claim an active
        // session when Closed-Lid Mode never actually engaged.
        XCTAssertEqual(mockPower.activeCount, 0)
        XCTAssertFalse(sessionManager.isSessionActive)
        XCTAssertNil(sessionManager.activeSession)
    }

    func testFailedClosedLidRevertIsSurfacedInsteadOfReportedAsACleanStop() async throws {
        try await sessionManager.startSession(
            duration: .preset(600),
            allowDisplaySleep: true,
            closedLidMode: true
        )
        XCTAssertTrue(sessionManager.isSessionActive)

        mockPrivileged.disableShouldFail = true
        await sessionManager.stopSession()

        XCTAssertFalse(sessionManager.isSessionActive)
        XCTAssertNotNil(
            sessionManager.lastAutomaticStopReason,
            "The user must be told that normal sleep behavior could not be restored."
        )
        XCTAssertTrue(
            sessionManager.lastAutomaticStopReason?.contains("Restore Normal Sleep") ?? false,
            "The message must point to the in-app remedy."
        )
        XCTAssertTrue(sessionManager.isSleepDisabledOutsideSession)
        mockPrivileged.disableShouldFail = false
    }

    func testPresetSessionExpiresAuthoritativelyViaMonotonicClock() async throws {
        try await sessionManager.startSession(
            duration: .preset(0.2),
            allowDisplaySleep: true,
            closedLidMode: false
        )
        XCTAssertTrue(sessionManager.isSessionActive)

        try await Task.sleep(for: .milliseconds(600))

        XCTAssertFalse(sessionManager.isSessionActive)
        XCTAssertEqual(mockPower.activeCount, 0)
    }

    func testUntilSessionRetainsWallClockSemantics() async throws {
        let target = Date().addingTimeInterval(0.2)
        try await sessionManager.startSession(
            duration: .until(target),
            allowDisplaySleep: true,
            closedLidMode: false
        )
        XCTAssertTrue(sessionManager.isSessionActive)

        try await Task.sleep(for: .milliseconds(900))

        XCTAssertFalse(sessionManager.isSessionActive)
    }

    func testActivationImmediatelyFollowedByStopLeavesNoResidualState() async throws {
        try await sessionManager.startSession(
            duration: .preset(600),
            allowDisplaySleep: true,
            closedLidMode: true
        )
        await sessionManager.stopSession()

        XCTAssertFalse(sessionManager.isSessionActive)
        XCTAssertEqual(mockPower.activeCount, 0)
        let closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertFalse(closedLidActive)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
    }

    /// Regression test: stopping a Closed-Lid session suspends while the privileged revert
    /// runs. An Extend arriving in that window (for example clicked just as the session
    /// expired) used to resurrect the session and re-enable Closed-Lid Mode after it had been
    /// turned off, leaving the Mac unable to sleep with no session left to restore it.
    func testExtendDuringStopDoesNotReEnableClosedLidMode() async throws {
        try await sessionManager.startSession(duration: .preset(600), allowDisplaySleep: true, closedLidMode: true)

        let gate = DispatchSemaphore(value: 0)
        mockPrivileged.disableGate = gate
        let stop = Task { await sessionManager.stopSession() }
        // Wait until the stop is blocked inside the privileged revert.
        while mockPrivileged.disableCallsCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        let extend = Task { await sessionManager.extendSession(by: SessionDuration.fifteenMinutes) }
        try await Task.sleep(for: .milliseconds(50))
        mockPrivileged.disableGate = nil
        gate.signal()
        await stop.value
        await extend.value

        XCTAssertNil(sessionManager.activeSession)
        let closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertFalse(closedLidActive, "Closed-Lid Mode must stay off once its session was stopped.")
        XCTAssertFalse(mockPrivileged.sleepDisabled)
    }

    /// Regression test: the low-battery cutoff turns Closed-Lid Mode off inside the
    /// controller, so the session stop that follows used to find an already inactive
    /// controller and report a clean stop even when normal sleep could not be restored.
    func testLowBatteryCutoffReportsWhenNormalSleepCouldNotBeRestored() async throws {
        try await sessionManager.startSession(duration: .preset(600), allowDisplaySleep: true, closedLidMode: true)
        mockPrivileged.disableShouldFail = true

        mockSource.triggerPowerChange(
            PowerSourceState(hasExternalPower: false, isCharging: false, batteryLevel: 9, isLowBattery: true)
        )

        let deadline = Date().addingTimeInterval(2)
        while sessionManager.lastAutomaticStopReason == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(sessionManager.isSessionActive)
        let reason = sessionManager.lastAutomaticStopReason ?? ""
        XCTAssertTrue(reason.contains("could not be restored"), "The user must learn that sleep may still be disabled, got: \(reason)")
        mockPrivileged.disableShouldFail = false
    }

    func testConcurrentStartsRunOneAfterAnother() async throws {
        let first = Task { try await sessionManager.startSession(duration: .preset(600), allowDisplaySleep: true, closedLidMode: true) }
        let second = Task { try await sessionManager.startSession(duration: .preset(900), allowDisplaySleep: true, closedLidMode: false) }
        try await first.value
        try await second.value

        XCTAssertEqual(sessionManager.activeSession?.duration, .preset(900))
        let closedLidActive = await closedLidController.isClosedLidActive
        XCTAssertFalse(closedLidActive, "The replaced Closed-Lid session must have been stopped.")
        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPower.activeCount, 1)
    }

    func testSleepDisabledOutsideASessionIsReportedAndCanBeRestored() async throws {
        // E.g. left behind by another tool: Meth reports it but never reverts it on its own.
        mockPrivileged.sleepDisabled = true
        await sessionManager.refreshSleepState()
        XCTAssertTrue(sessionManager.isSleepDisabledOutsideSession)
        XCTAssertTrue(mockPrivileged.sleepDisabled)

        try await sessionManager.restoreNormalSleep()

        XCTAssertFalse(sessionManager.isSleepDisabledOutsideSession)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
    }

    func testFailedStopCanBeRecoveredWithRestoreNormalSleep() async throws {
        try await sessionManager.startSession(duration: .preset(600), allowDisplaySleep: true, closedLidMode: true)
        mockPrivileged.disableShouldFail = true
        await sessionManager.stopSession()
        XCTAssertTrue(sessionManager.isSleepDisabledOutsideSession)
        mockPrivileged.disableShouldFail = false

        try await sessionManager.restoreNormalSleep()

        XCTAssertFalse(sessionManager.isSleepDisabledOutsideSession)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
    }

    func testSessionEndDate() async throws {
        try await sessionManager.startSession(duration: .indefinite, allowDisplaySleep: true, closedLidMode: false)
        XCTAssertNil(sessionManager.sessionEndDate)

        try await sessionManager.startSession(duration: .preset(600), allowDisplaySleep: true, closedLidMode: false)
        let presetEnd = try XCTUnwrap(sessionManager.sessionEndDate)
        XCTAssertLessThan(abs(presetEnd.timeIntervalSinceNow - 600), 2)

        let target = Date().addingTimeInterval(3600)
        try await sessionManager.startSession(duration: .until(target), allowDisplaySleep: true, closedLidMode: false)
        XCTAssertEqual(sessionManager.sessionEndDate, target)
    }
}
