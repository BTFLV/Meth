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
}
