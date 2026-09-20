import Foundation

#if canImport(XCTest)
import XCTest
#else

@MainActor
open class XCTestCase {
    public init() {}
    open func setUp() {}
    open func tearDown() {}

    public func expectation(description: String) -> XCTestExpectation {
        return XCTestExpectation(description: description)
    }

    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if expectations.allSatisfy({ $0.isFulfilled }) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if !expectations.allSatisfy({ $0.isFulfilled }) {
            XCTFail("Expectations timed out after \(timeout)s: \(expectations.filter { !$0.isFulfilled }.map { $0.description })")
        }
    }
}

public final class XCTestExpectation: @unchecked Sendable {
    public let description: String
    private let lock = NSLock()
    private var _isFulfilled = false

    public var isFulfilled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isFulfilled
    }

    public init(description: String) {
        self.description = description
    }

    public func fulfill() {
        lock.lock()
        _isFulfilled = true
        lock.unlock()
    }
}

public func XCTAssertEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a != b {
        fatalError("Assertion failure: \(String(describing: a)) != \(String(describing: b)). \(message) at \(file):\(line)")
    }
}

public func XCTAssertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if !condition {
        fatalError("Assertion failure: Expected true. \(message) at \(file):\(line)")
    }
}

public func XCTAssertFalse(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if condition {
        fatalError("Assertion failure: Expected false. \(message) at \(file):\(line)")
    }
}

public func XCTAssertNil(_ value: Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if value != nil {
        fatalError("Assertion failure: Expected nil, got \(String(describing: value)). \(message) at \(file):\(line)")
    }
}

public func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
    if a <= b {
        fatalError("Assertion failure: \(a) is not greater than \(b). \(message) at \(file):\(line)")
    }
}

public func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) {
    fatalError("XCTFail: \(message) at \(file):\(line)")
}

public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) {
    do {
        _ = try expression()
        fatalError("Assertion failure: Expected error to be thrown, but succeeded. \(message) at \(file):\(line)")
    } catch {
        errorHandler(error)
    }
}

#endif

public struct TestRunner {
    @MainActor
    public static func runAll() {
        print("Running Meth test suite...")

        print("-> SessionTests...")
        let sTests = SessionTests()
        sTests.setUp()
        sTests.testPresetDurationEndDate()
        sTests.testIndefiniteDurationEndDate()
        sTests.testUntilDateCalculationFutureToday()
        sTests.testUntilDateCalculationPastRollsOverToTomorrow()
        sTests.testSessionRemainingTimeAndExpiration()
        sTests.testSessionExtension()
        sTests.testFormatRemaining()
        sTests.tearDown()
        print("   Passed SessionTests")

        print("-> SessionManagerTests...")
        let smTests = SessionManagerTests()
        smTests.setUp()
        try! smTests.testStartNormalSessionWithDisplaySleepAllowed()
        smTests.tearDown()

        smTests.setUp()
        try! smTests.testStartSessionWithDisplaySleepDisallowed()
        smTests.tearDown()

        smTests.setUp()
        try! smTests.testStartClosedLidSession()
        smTests.tearDown()

        smTests.setUp()
        try! smTests.testStopSessionCleansUpAllState()
        smTests.tearDown()

        smTests.setUp()
        try! smTests.testSessionReplacementSafelyCleansUpOldSession()
        smTests.tearDown()

        smTests.setUp()
        try! smTests.testExtendSession()
        smTests.tearDown()

        smTests.setUp()
        smTests.testClosedLidSupportNotInstalledThrows()
        smTests.tearDown()
        print("   Passed SessionManagerTests")

        print("-> ClosedLidControllerTests...")
        let clTests = ClosedLidControllerTests()
        clTests.setUp()
        try! clTests.testActivationAndDeactivationLifecycle()
        clTests.tearDown()

        clTests.setUp()
        try! clTests.testLidCloseTriggersDisplaySleep()
        clTests.tearDown()

        clTests.setUp()
        try! clTests.testLowBatteryTriggersSafetyCutoff()
        clTests.tearDown()

        clTests.setUp()
        try! clTests.testAppleSiliconPowerSourceTransitionReEnforcesSleepDisabled()
        clTests.tearDown()
        print("   Passed ClosedLidControllerTests")

        print("-> FailsafeRecoveryTests...")
        let fsTests = FailsafeRecoveryTests()
        fsTests.setUp()
        fsTests.testStartupRecoveryCleansStaleSleepDisabledState()
        fsTests.tearDown()

        fsTests.setUp()
        fsTests.testStartupRecoveryDoesNothingIfSleepAlreadyEnabled()
        fsTests.tearDown()
        print("   Passed FailsafeRecoveryTests")

        print("All 15 tests passed successfully!")
    }
}

