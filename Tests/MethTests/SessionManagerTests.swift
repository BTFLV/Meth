import Foundation
#if canImport(XCTest)
import XCTest
#endif
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
            powerMonitor: mockSource
        )

        sessionManager = SessionManager(
            powerAssertionManager: mockPower,
            closedLidController: closedLidController,
            privilegedService: mockPrivileged
        )
    }

    override func tearDown() {
        sessionManager.stopSession()
        super.tearDown()
    }

    func testStartNormalSessionWithDisplaySleepAllowed() throws {
        try sessionManager.startSession(
            duration: .preset(3600),
            allowDisplaySleep: true,
            closedLidMode: false
        )

        XCTAssertTrue(sessionManager.isSessionActive)
        XCTAssertEqual(mockPower.createdAssertions.count, 1)
        XCTAssertEqual(mockPower.createdAssertions.first?.type, .preventUserIdleSystemSleep)
        XCTAssertFalse(closedLidController.isClosedLidActive)
    }

    func testStartSessionWithDisplaySleepDisallowed() throws {
        try sessionManager.startSession(
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

    func testStartClosedLidSession() throws {
        try sessionManager.startSession(
            duration: .preset(1800),
            allowDisplaySleep: true,
            closedLidMode: true
        )

        XCTAssertTrue(sessionManager.isSessionActive)
        XCTAssertTrue(closedLidController.isClosedLidActive)
        XCTAssertTrue(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.enableCallsCount, 1)
    }

    func testStopSessionCleansUpAllState() throws {
        try sessionManager.startSession(
            duration: .preset(1800),
            allowDisplaySleep: false,
            closedLidMode: true
        )

        XCTAssertTrue(sessionManager.isSessionActive)
        XCTAssertTrue(closedLidController.isClosedLidActive)

        sessionManager.stopSession()

        XCTAssertFalse(sessionManager.isSessionActive)
        XCTAssertNil(sessionManager.activeSession)
        XCTAssertEqual(mockPower.activeCount, 0)
        XCTAssertFalse(closedLidController.isClosedLidActive)
        XCTAssertFalse(mockPrivileged.sleepDisabled)
        XCTAssertEqual(mockPrivileged.disableCallsCount, 1)
    }

    func testSessionReplacementSafelyCleansUpOldSession() throws {
        try sessionManager.startSession(
            duration: .preset(3600),
            allowDisplaySleep: false,
            closedLidMode: false
        )

        XCTAssertEqual(mockPower.createdAssertions.count, 2)
        XCTAssertEqual(mockPower.releasedAssertionIDs.count, 0)

        // Replace session with a 15-minute closed-lid session
        try sessionManager.startSession(
            duration: .preset(900),
            allowDisplaySleep: true,
            closedLidMode: true
        )

        // Previous 2 assertions must be released, new 1 assertion created
        XCTAssertEqual(mockPower.releasedAssertionIDs.count, 2)
        XCTAssertEqual(mockPower.activeCount, 1)
        XCTAssertTrue(closedLidController.isClosedLidActive)
    }

    func testExtendSession() throws {
        try sessionManager.startSession(
            duration: .preset(600),
            allowDisplaySleep: true,
            closedLidMode: false
        )

        let initialRemaining = sessionManager.remainingTime ?? 0
        sessionManager.extendSession(by: 900)
        let extendedRemaining = sessionManager.remainingTime ?? 0

        XCTAssertGreaterThan(extendedRemaining, initialRemaining + 800)
    }

    func testClosedLidSupportNotInstalledThrows() {
        mockPrivileged.isSupportInstalled = false

        XCTAssertThrowsError(
            try sessionManager.startSession(
                duration: .preset(600),
                allowDisplaySleep: true,
                closedLidMode: true
            )
        ) { error in
            guard let clError = error as? ClosedLidError else {
                XCTFail("Expected ClosedLidError, got \(error)")
                return
            }
            XCTAssertEqual(clError, .supportNotInstalled)
        }

        // Must not leak any assertions if startup throws
        XCTAssertEqual(mockPower.activeCount, 0)
        XCTAssertFalse(sessionManager.isSessionActive)
    }
}
